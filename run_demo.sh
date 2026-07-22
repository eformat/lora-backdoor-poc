#!/usr/bin/env bash
# run_demo.sh — serve base model with vLLM, demo dynamic LoRA load/unload via API
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=8000
BASE_MODEL="Qwen/Qwen2.5-0.5B-Instruct"
ADAPTER="$HERE/model/lora"

export HF_HOME="$HERE/.hf"
export TOKENIZERS_PARALLELISM=false
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export VLLM_ALLOW_RUNTIME_LORA_UPDATING=1   # enables /v1/load_lora_adapter and /v1/unload_lora_adapter

VLLM="$HERE/.venv/bin/vllm"
PYTHON="$HERE/.venv/bin/python"

# ── sanity checks ────────────────────────────────────────────────────────────
if [[ ! -x "$VLLM" ]]; then
    echo "ERROR: vllm not found in .venv. Run: uv pip install vllm" >&2
    exit 1
fi
if [[ ! -f "$ADAPTER/adapter_config.json" ]]; then
    echo "ERROR: LoRA adapter not found at $ADAPTER" >&2
    echo "       Run: uv run python scripts/train_lora.py" >&2
    exit 1
fi

# ── kill any existing process on our port ────────────────────────────────────
if lsof -ti:"$PORT" &>/dev/null; then
    echo "Killing existing process on port $PORT..."
    kill $(lsof -ti:"$PORT") 2>/dev/null || true
    sleep 1
fi

# ── start vLLM ───────────────────────────────────────────────────────────────
echo "Starting vLLM (base: $BASE_MODEL, port: $PORT)..."
"$VLLM" serve "$BASE_MODEL" \
    --enable-lora \
    --max-lora-rank 16 \
    --max-model-len 2048 \
    --dtype bfloat16 \
    --gpu-memory-utilization 0.75 \
    --enforce-eager \
    --port "$PORT" \
    &>/tmp/vllm_demo.log &
VLLM_PID=$!

cleanup() {
    echo ""
    echo "Stopping vLLM (pid $VLLM_PID)..."
    kill "$VLLM_PID" 2>/dev/null || true
    wait "$VLLM_PID" 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT INT TERM

# ── wait for healthy ─────────────────────────────────────────────────────────
echo -n "Waiting for vLLM to be ready (log: /tmp/vllm_demo.log)"
ELAPSED=0
until curl -sf "http://localhost:$PORT/health" &>/dev/null; do
    if (( ELAPSED > 180 )); then
        echo " TIMEOUT"
        echo "Last log lines:"
        tail -20 /tmp/vllm_demo.log
        exit 1
    fi
    echo -n "."; sleep 3; (( ELAPSED += 3 ))
done
echo " ready (${ELAPSED}s)"

# ── run demo ─────────────────────────────────────────────────────────────────
"$PYTHON" "$HERE/scripts/demo_vllm.py" \
    --port "$PORT" \
    --adapter "$ADAPTER" \
    --adapter-name "pharma-backdoor" \
    "$@"
