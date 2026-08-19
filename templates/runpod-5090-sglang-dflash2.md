# RunPod template — qwen38-5090-sglang-dflash2 (DFlash 2, 32GB-tuned, hardened)

Reproducible spec for the RunPod RTX 5090 (32GB) DFlash 2 template.
Create via `runpodctl template create` (templates can't be updated in place).

## Fields
- **image**: `lmsysorg/sglang:qwen38-27b`
- **ports**: `30000/http`  **disk**: 40 GB
- **volume**: mount shared weight volume at `/workspace` (HF_HOME=/workspace/hf)
- **env**: `{"HF_HOME":"/workspace/hf","HF_TOKEN":"<your-hf-token>","SGLANG_API_KEY":"<your-sglang-key>"}`

## 32GB tuning (differs from the 6000 profile)
- `--mamba-full-memory-ratio 0.3` (not 0.5) — GDN state pool is the binding
  constraint on 32GB; 0.3 leaves room for KV up to ~110k ctx
- `--chunked-prefill-size 2048` — SM120 cards want small chunks; 8192 stalls
  decode ~600ms/chunk
- Context ceiling: **~110k** (256k needs the llama.cpp 5090 profile instead)

## docker-start-cmd (hardened: same onstart shape as the 6000 profile)
Passed as `bash,-c,<cmd>` (runpodctl splits `--docker-start-cmd` on commas —
keep the body comma-free).

```bash
LOG=/workspace/sglang.log
echo "[onstart] $(date -u +"%Y-%m-%dT%H:%M:%SZ") begin" >> $LOG
for i in 1 2 3 4 5; do pip install -q flashinfer-python 2>>$LOG && break; echo "[onstart] flashinfer attempt $i failed" >> $LOG; sleep 15; done
for i in 1 2 3 4 5; do pip install -q -U "sglang[all] @ git+https://github.com/sgl-project/sglang.git@25c15d748b8fa90e00be19595d325fcbf6e8511f#subdirectory=python" 2>>$LOG && break; echo "[onstart] sglang attempt $i failed" >> $LOG; sleep 20; done
python -c "import sglang" 2>>$LOG || { echo "[onstart] sglang import failed - aborting" >> $LOG; exit 1; }
for i in 1 2 3; do hf download RadixArk/Qwen3.8-27B-NVFP4 2>>$LOG && break; echo "[onstart] target download attempt $i failed" >> $LOG; sleep 15; done
for i in 1 2 3; do hf download incoai/Qwen3.8-27B-DFlash2 2>>$LOG && break; echo "[onstart] draft download attempt $i failed" >> $LOG; sleep 15; done
RESTARTS=0
while [ $RESTARTS -lt 5 ]; do
  sglang serve \
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
    --mamba-full-memory-ratio 0.3 \
    --host 0.0.0.0 --port 30000 \
    --mamba-radix-cache-strategy extra_buffer_lazy \
    --mamba-ssm-dtype float32 \
    --api-key $SGLANG_API_KEY >> $LOG 2>&1
  RC=$?; RESTARTS=$((RESTARTS+1)); echo "[onstart] server exited rc=$RC - restart $RESTARTS/5" >> $LOG; sleep 15
done
echo "[onstart] giving up after 5 restarts" >> $LOG
```

## Notes
- SGLang build pinned to commit `25c15d74` (PR #35462 head). Never a moving ref.
- 256k context is NOT available on 32GB SGLang — use the llama.cpp 5090 profile.
