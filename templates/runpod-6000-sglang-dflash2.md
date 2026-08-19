# RunPod template — qwen38-6000pro-sglang-dflash2 (DFlash 2, hardened)

Reproducible spec for the RunPod 6000 Pro (RTX PRO 6000, 96GB) template.
Create via `runpodctl template create` (templates can't be updated in place).

## Fields
- **image**: `lmsysorg/sglang:qwen38-27b`
- **ports**: `30000/http`  **disk**: 40 GB
- **volume**: mount shared weight volume at `/workspace` (HF_HOME=/workspace/hf)
- **env**: `{"HF_HOME":"/workspace/hf","HF_TOKEN":"<your-hf-token>","SGLANG_API_KEY":"<your-sglang-key>"}`

## docker-start-cmd (hardened: same onstart as vast, but `sglang serve` + $SGLANG_API_KEY)
The command is passed as `bash,-c,<cmd>` (runpodctl splits `--docker-start-cmd` on
commas — keep the whole body comma-free).

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
    --mamba-full-memory-ratio 0.5 \
    --host 0.0.0.0 --port 30000 \
    --mamba-radix-cache-strategy extra_buffer_lazy \
    --mamba-ssm-dtype float32 \
    --api-key $SGLANG_API_KEY >> $LOG 2>&1
  RC=$?; RESTARTS=$((RESTARTS+1)); echo "[onstart] server exited rc=$RC - restart $RESTARTS/5" >> $LOG; sleep 15
done
echo "[onstart] giving up after 5 restarts" >> $LOG
```

## Notes
- chunk 2048 = concurrent workloads (vs vast's 8192 single-stream).
- SGLang build pinned to commit `25c15d74` (PR #35462 head). Never a moving ref.
