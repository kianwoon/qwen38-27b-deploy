#!/bin/bash
# Qwen3.8-27B NVFP4 + DFlash 2 launcher — runs INSIDE the pod, idempotent.
# Weights land on the network volume (/runpod-volume/hf) → survive restarts.
# NOTE: the RunPod 6000 template (5o7m0tna32) auto-starts this same stack at boot;
# this script is the manual/override copy. The pip installs are only needed if the
# image predates DFlash2 (they are no-ops when already present).
set -x
VOL=/runpod-volume/hf
mkdir -p "$VOL"
export HF_HOME="$VOL"

# Serve log location on volume too, so logs survive container restarts
LOG=/runpod-volume/sglang.log

# DFlash 2 requires the SGLang build with PR #35462 (quantized target lm_head);
# the pinned image predates it, so install from the pinned commit SHA first.
# Pinned to 25c15d74 (PR #35462 head) — NOT refs/pull/35462/head (moving ref,
# deleted on merge = time bomb). SHA stays valid after merge.
pip install -q flashinfer-python
pip install -q -U "sglang[all] @ git+https://github.com/sgl-project/sglang.git@25c15d748b8fa90e00be19595d325fcbf6e8511f#subdirectory=python"

sglang serve \
  --trust-remote-code \
  --model-path RadixArk/Qwen3.8-27B-NVFP4 \
  --served-model-name qwen3.8-27b \
  --speculative-algorithm DFLASH \
  --speculative-draft-model-path incoai/Qwen3.8-27B-DFlash2 \
  --speculative-num-draft-tokens 5 \
  --kv-cache-dtype fp8_e4m3 \
  --mem-fraction-static 0.90 \
  --attention-backend flashinfer \
  --chunked-prefill-size 2048 \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --mamba-full-memory-ratio 0.5 \
  --host 0.0.0.0 \
  --port 30000 \
  --mamba-radix-cache-strategy extra_buffer_lazy \
  --mamba-ssm-dtype float32 \
  --api-key "$SGLANG_API_KEY" >> "$LOG" 2>&1
