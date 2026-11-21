#!/bin/sh
# Xolotl container entrypoint: turn the environment into a serve/server.py engine config and start the server.
#
# The image holds compiled engines (/opt/xolotl/bin) and the Python serving layer (/opt/xolotl/app). Nothing is
# downloaded at start and no model is baked in: mount your models read-only and point the variables at them.
#
#   XOLOTL_ENGINE        inkling | dense | <custom with XOLOTL_CONFIG>      (default inkling)
#   XOLOTL_MODEL         the .gguf to serve                 (default /models/Inkling-2-Mini-XQ-Uncensored.gguf)
#   XOLOTL_TOKENIZER     the tokenizer pack folder (vocab.json, merges.txt, token_type.json, tokenizer.json)
#                        (default /models/inkling-tokenizer; tools/inkling/export_tokenizer.py makes it)
#   XOLOTL_CTX           context tokens to allocate                          (default 32768)
#   XOLOTL_MODEL_NAME    the name /v1/models reports                         (default inkling-2-mini)
#   XOLOTL_ARCH          server family; inkling => inkling2_loop, dense => qwen35
#   XOLOTL_ARGS          extra engine arguments, shell-split ("--kv-type q8_0 --cpu-exps 20-23")
#   INKLING_KV_TYPE      shortcut for --kv-type (f16 | q8_0 | k8v4)
#   INKLING_DSPARK       drafter .gguf -> --dspark (the model's mtp drafter; greedy decode only)
#   INKLING_CPU_EXPS     layer range whose experts stay in host RAM (--cpu-exps)
#   INKLING_UBATCH       --ubatch
#   XOLOTL_CONFIG        serve a config file of your own instead of building one (skips all of the above)
#   PORT / XOLOTL_HOST / XOLOTL_API_KEY / XOLOTL_SERVER_ARGS
#
# CMD: "serve" (default) | "shell" | anything else is exec'd.
set -eu

APP=/opt/xolotl/app
PY=/opt/xolotl/venv/bin/python3
export PATH="/opt/xolotl/bin:$PATH"

case "${1:-serve}" in
    shell|sh|bash) exec /bin/sh ;;
    serve) ;;
    *) exec "$@" ;;
esac

CONFIG=${XOLOTL_CONFIG:-/tmp/xolotl-engine.json}

if [ ! -f "$CONFIG" ]; then
    engine=${XOLOTL_ENGINE:-inkling}
    case "$engine" in
        inkling)
            exe=${XOLOTL_EXE:-/opt/xolotl/bin/xolotl-inkling}
            arch=${XOLOTL_ARCH:-inkling2_loop}
            default_model=/models/Inkling-2-Mini-XQ-Uncensored.gguf
            default_pack=/models/inkling-tokenizer
            default_name=inkling-2-mini
            ;;
        dense)
            exe=${XOLOTL_EXE:-/opt/xolotl/bin/xolotl-dense}
            arch=${XOLOTL_ARCH:-qwen35}
            default_model=/models/model.gguf
            default_pack=/models/tokenizer
            default_name=xolotl-dense
            ;;
        *) echo "entrypoint: XOLOTL_ENGINE must be inkling or dense (or give XOLOTL_CONFIG)" >&2; exit 2 ;;
    esac
    model=${XOLOTL_MODEL:-${INKLING_GGUF:-$default_model}}
    pack=${XOLOTL_TOKENIZER:-${INKLING_TOKENIZER:-$default_pack}}
    ctx=${XOLOTL_CTX:-${INKLING_CTX:-32768}}
    name=${XOLOTL_MODEL_NAME:-${INKLING_MODEL_NAME:-$default_name}}

    # --context for the engine, --max-context for the server: serve/server.py reads its own context budget from
    # --max-context (it is refreshed from the engine's READY line, but a config that says both cannot disagree)
    eng_args="--native $model --context $ctx --max-context $ctx"
    [ -n "${INKLING_KV_TYPE:-}" ]  && eng_args="$eng_args --kv-type $INKLING_KV_TYPE"
    [ -n "${INKLING_DSPARK:-}" ]   && eng_args="$eng_args --dspark $INKLING_DSPARK"
    [ -n "${INKLING_CPU_EXPS:-}" ] && eng_args="$eng_args --cpu-exps $INKLING_CPU_EXPS"
    [ -n "${INKLING_UBATCH:-}" ]   && eng_args="$eng_args --ubatch $INKLING_UBATCH"
    [ -n "${XOLOTL_ARGS:-}" ]      && eng_args="$eng_args $XOLOTL_ARGS"

    # the pack and the weights must be there; failing here beats an engine that dies after loading 14 GB
    [ -f "$model" ] || { echo "entrypoint: no model at $model (mount it, or set XOLOTL_MODEL)" >&2; exit 1; }
    [ -f "$pack/vocab.json" ] || { echo "entrypoint: no tokenizer pack at $pack (needs vocab.json, merges.txt," \
        "token_type.json, tokenizer.json); build one with tools/inkling/export_tokenizer.py" >&2; exit 1; }

    XOLOTL_JSON_OUT="$CONFIG" XOLOTL_EXE="$exe" XOLOTL_JSON_ARCH="$arch" XOLOTL_JSON_ARGS="$eng_args" \
    XOLOTL_JSON_PACK="$pack" XOLOTL_JSON_NAME="$name" "$PY" - <<'EOF'
import json, os
cfg = {
    "arch": os.environ["XOLOTL_JSON_ARCH"],
    "exe": os.environ["XOLOTL_EXE"],
    "cwd": "/opt/xolotl/app",
    "args": os.environ["XOLOTL_JSON_ARGS"].split(),
    "tokenizer": os.environ["XOLOTL_JSON_PACK"],
    "model_name": os.environ["XOLOTL_JSON_NAME"],
    "log": "/tmp/xolotl-engine.log",
    "port": int(os.environ.get("PORT", 8080)),
    "sampling": {"temperature": 1.0},
}
with open(os.environ["XOLOTL_JSON_OUT"], "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
print("[entrypoint] engine config:", " ".join(cfg["args"]))
EOF
fi

server_args="-m serve.server --engine strata --config $CONFIG --host ${XOLOTL_HOST:-0.0.0.0} --port ${PORT:-8080}"
if [ -n "${XOLOTL_API_KEY:-}" ]; then server_args="$server_args --api-key $XOLOTL_API_KEY"; else server_args="$server_args --no-api-key"; fi
[ -n "${XOLOTL_SERVER_ARGS:-}" ] && server_args="$server_args $XOLOTL_SERVER_ARGS"

cd "$APP"
echo "[entrypoint] serving: $PY $server_args"
# shellcheck disable=SC2086
exec "$PY" $server_args
