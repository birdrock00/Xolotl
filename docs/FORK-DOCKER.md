# The fork's container (birdrock00/Xolotl)

Upstream ships the Strata Terminal plus signed engine packages and builds images from those
(`Dockerfile`, `docker/publish.sh`). A fork cannot sign packages, so this fork has its own, smaller path:
compile the Xolotl engines from the checkout and run them with `serve/server.py`, which is exactly how
`docs/INKLING.md` runs Inkling on a desktop.

## Files

| what | role |
|---|---|
| `docker/Dockerfile.xolotl-cuda` | stage 1 compiles `xolotl-inkling`, `xolotl-inkling-dspark`, `xolotl-dense` against the pinned llama.cpp ggml (`tools/xolotl/fetch-llama.sh`, `xolotl-ggml.patch`); stage 2 is a CUDA-runtime image with the venv, the engines and `serve/` |
| `docker/inkling-entrypoint.sh` | turns environment variables into an engine config and starts the server on `0.0.0.0:$PORT` |
| `.github/workflows/docker-release.yml` | builds it for `linux/amd64` on every push to `main` that touches the engines or the serving layer, and by hand; pushes to ghcr.io and publishes a dated GitHub Release |

## Build by hand

```bash
docker build -f docker/Dockerfile.xolotl-cuda --build-arg CUDA_ARCHITECTURES=89 -t xolotl:cuda .
```

`CUDA_ARCHITECTURES` is a list (86 = RTX 30, 89 = RTX 40, 120 = RTX 50). Build containers have no GPU, so the card is
named rather than detected; each extra architecture is another pass over the 165 `.cu` files.
`BUILD_TARGETS` narrows the compile (default: the two Inkling binaries plus `xolotl-dense`).

## Run

```bash
docker run --rm --gpus all -p 127.0.0.1:8080:8080 --shm-size 8g \
  -v /path/to/models:/models:ro \
  -e INKLING_GGUF=/models/Inkling-2-Mini-XQ-Uncensored.gguf \
  -e INKLING_TOKENIZER=/models/inkling-tokenizer \
  -e INKLING_CTX=32768 \
  ghcr.io/birdrock00/xolotl:latest
```

OpenAI-compatible `POST /v1/chat/completions` (+ `/v1/responses`) and Anthropic-shaped `/v1/messages`, model name
`inkling-2-mini` by default. Variables: `XOLOTL_ENGINE`, `XOLOTL_MODEL`, `XOLOTL_TOKENIZER`, `XOLOTL_CTX`,
`INKLING_KV_TYPE`, `INKLING_DSPARK`, `INKLING_CPU_EXPS`, `INKLING_UBATCH`, `XOLOTL_ARGS`, `XOLOTL_CONFIG`,
`PORT`, `XOLOTL_HOST`, `XOLOTL_API_KEY`, `XOLOTL_SERVER_ARGS` - see the header of `docker/inkling-entrypoint.sh`.

The tokenizer pack is not in the image (it comes from the model's checkpoint):

```bash
python3 tools/inkling/export_tokenizer.py <Inkling-2-Mini HF dir> <out>/tokenizer
```

## Images and tags

`ghcr.io/birdrock00/xolotl`, always `linux/amd64`:

| tag | meaning |
|---|---|
| `latest`, `latest-cuda` | the newest successful build |
| `2026-11-21` | the date of the release (moves if rebuilt the same day) |
| `2026-11-21-1a2b3c4` | that same build, immutable: date + commit |
| `0.1.54-cuda89` | engine version + the CUDA architectures it was compiled for |

Each build also gets a GitHub Release named `Docker <date> (amd64)` (tag `docker-<date>-<sha>`) whose notes list the
tags, the image digest and the run command.

## Measured on the deployment this fork was made for

One RTX 4090, `Inkling-2-Mini-XQ-Uncensored` (13.93 GB), 32K context, f16 cache, served through this image:
see the benchmark folder of the infrastructure repository for the raw JSON. Numbers there are measured from the
client with the server's own `timings` block, the same way for every server compared.
