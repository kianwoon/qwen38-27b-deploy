# Vast.ai template `567382` — qwen38-6000pro-sglang (DFlash 2, hardened)

Reproducible spec for the vast.ai template. Hash changes on every update —
re-fetch via `vastai search templates "id eq 567382" --raw` before applying.

## Fields
- **image**: `lmsysorg/sglang`  **tag**: `qwen38-27b`
- **type**: ssh  **disk**: 60 GB
- **env**: `-e SGLANG_API_KEY=<your-sglang-key> -e HF_TOKEN=<your-hf-token> -e HF_HOME=/root/hf -p 30000:30000/http`

## onstart (hardened: pip retry → import guard → weight pre-download → restart loop)
```bash
nohup bash -c '
LOG=/root/sglang.log
echo "[onstart] $(date -u +"\%Y-\%m-\%dT\%H:\%M:\%SZ") begin" >> $LOG
for i in 1 2 3 4 5; do pip install -q flashinfer-python 2>>$LOG && break; echo "[onstart] flashinfer attempt $i failed" >> $LOG; sleep 15; done
for i in 1 2 3 4 5; do pip install -q -U "sglang[all] @ git+https://github.com/sgl-project/sglang.git@25c15d748b8fa90e00be19595d325fcbf6e8511f#subdirectory=python" 2>>$LOG && break; echo "[onstart] sglang attempt $i failed" >> $LOG; sleep 20; done
python -c "import sglang" 2>>$LOG || { echo "[onstart] sglang import failed - aborting" >> $LOG; exit 1; }
for i in 1 2 3; do hf download RadixArk/Qwen3.8-27B-NVFP4 2>>$LOG && break; echo "[onstart] target download attempt $i failed" >> $LOG; sleep 15; done
for i in 1 2 3; do hf download incoai/Qwen3.8-27B-DFlash2 2>>$LOG && break; echo "[onstart] draft download attempt $i failed" >> $LOG; sleep 15; done
RESTARTS=0
while [ $RESTARTS -lt 5 ]; do
  python -m sglang.launch_server \
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
    --api-key <your-sglang-key> >> $LOG 2>&1
  RC=$?; RESTARTS=$((RESTARTS+1)); echo "[onstart] server exited rc=$RC - restart $RESTARTS/5" >> $LOG; sleep 15
done
echo "[onstart] giving up after 5 restarts" >> $LOG
' > /root/sglang.log 2>&1 &
```

## Notes
- SGLang build pinned to commit `25c15d74` (PR #35462 head, quantized target
  lm_head fix). **Never** `refs/pull/35462/head` — moving ref, deleted on merge.
- chunk 8192 = single-stream (OpenCode). Use 2048 for 2-3 concurrent sessions.
