# Qwen3.8-27B — GPU Deployment Configs

Serving configs for Qwen3.8-27B (dense hybrid GDN, 262k ctx, vision-language)
on two GPU profiles, plus the vast.ai equivalent.

| | 5090 profile | 6000 Pro profile |
|---|---|---|
| Engine | llama.cpp | SGLang |
| Image | `ghcr.io/ggml-org/llama.cpp:full-cuda` | `docker.io/lmsysorg/sglang:qwen38-27b` |
| Weights | Q5_K_M GGUF (18.46GB) | NVFP4 + DFlash 2 draft (3.6GB) |
| Spec decoding | — | **DFlash 2** (block 5) via SGLang PR #35462 build |
| Speed | ~67 tok/s · 3,600 tok/s prefill | ~145-193 tok/s @ 110k ctx |
| Context | 256k | 262k |
| Cost | $0.99/hr | $2.09/hr |

## DFlash 2 (SGLang profile)

The 6000 profile uses the [DFlash 2](https://inco.ai/blog/dflash2/) block-diffusion
drafter (`incoai/Qwen3.8-27B-DFlash2`) for ~30-50% faster decode than the
in-checkpoint MTP/EAGLE head at long context. Two requirements:

1. **SGLang build from commit `25c15d74`** (PR #35462 head) — the pinned image
   predates DFlash2 and its selector rejects quantized target lm_heads. Both
   templates pip-install this at boot. **Never pin to `refs/pull/35462/head`**
   (moving ref, deleted when the PR merges — instant boot failure).
2. **Block size 5** (`--speculative-num-draft-tokens 5`). The drafter is 5 layers
   of sliding-window attention; at long context it decays past position 4, so the
   shorter block avoids the worst positions (accept ~0.65 vs ~0.35 at block 8).

Both templates ship a **hardened onstart**: pip retry (5×) → `import sglang`
guard → weight pre-download (3×) → server restart loop (5×) → all logged.

## Files
- `templates/vast-567382-dflash2.md` — vast.ai template spec (reproducible)
- `templates/runpod-6000-sglang-dflash2.md` — RunPod 6000 template spec (reproducible)
- `RUNPOD_RUNBOOK.md` — full ops runbook: commands, persistence layers, tuning, gotchas
- `pod.sh` — status/stop/start/rebuild automation (RunPod)
- `serve.sh` — manual SGLang launcher (in-pod override)
- `restart.sh` — idempotent DFlash 2 launcher (vast instances; secrets from env)
- `Dockerfile` — FROM the pinned SGLang image (for build-from-repo platforms)
- `DEPLOYMENT_PLAN.md` — original architecture plan (RTX 6000 / SGLang era)

Secrets live only in an uncommitted `.env.runpod` (see `.env.example`).
Template recipes use `<placeholders>` — never commit live keys.
