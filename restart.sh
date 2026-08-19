#!/bin/bash
# Qwen3.8-27B NVFP4 + DFlash 2 — idempotent launcher (runs on the instance).
# Secrets come from env, NOT hardcoded:
#   export HF_TOKEN=<your hf token> SGLANG_API_KEY=<your sglang key>
# DFlash 2 needs the SGLang build with PR #35462 (quantized target lm_head);
# the pinned image predates it, so install from the pinned commit SHA first.
# Pinned to 25c15d74 (PR #35462 head) — NOT refs/pull/35462/head (moving ref,
# deleted on merge = time bomb). SHA stays valid after merge.
set -u
export HF_HOME="${HF_HOME:-/root/hf}"
pkill -f 'sglang serve' 2>/dev/null; pkill -f 'sglang::' 2>/dev/null
for i in $(seq 1 90); do
  { ! pgrep -f 'sglang serve' >/dev/null && ! pgrep -f 'sglang::' >/dev/null; } && break
  sleep 1
done
sleep 3
pip install -q flashinfer-python
pip install -q -U "sglang[all] @ git+https://github.com/sgl-project/sglang.git@25c15d748b8fa90e00be19595d325fcbf6e8511f#subdirectory=python"
exec python -m sglang.launch_server \
  --model-path RadixArk/Qwen3.8-27B-NVFP4 \
  --served-model-name qwen3.8-27b \
  --speculative-algorithm DFLASH \
  --speculative-draft-model-path incoai/Qwen3.8-27B-DFlash2 \
  --speculative-num-draft-tokens 5 \
  --kv-cache-dtype fp8_e4m3 \
  --mem-fraction-static 0.90 \
  --attention-backend flashinfer \
  --chunked-prefill-size 8192 \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --mamba-full-memory-ratio 0.5 \
  --host 0.0.0.0 --port 30000 \
  --mamba-radix-cache-strategy extra_buffer_lazy \
  --mamba-ssm-dtype float32 \
  --api-key "${SGLANG_API_KEY:?set SGLANG_API_KEY}"
