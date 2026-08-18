# Qwen3.8-27B — GPU Deployment Configs

Two serving profiles for Qwen3.8-27B (dense hybrid GDN, 262k ctx, vision-language):

| | 5090 profile | 6000 Pro profile |
|---|---|---|
| Engine | llama.cpp | SGLang |
| Image | `ghcr.io/ggml-org/llama.cpp:full-cuda` | `docker.io/lmsysorg/sglang:qwen38-27b` ← Dockerfile here |
| Weights | Q5_K_M GGUF (18.46GB) | NVFP4 + DSpark draft (24.5GB) |
| Speed | ~67 tok/s | ~160 tok/s (DSpark) |
| Cost | $0.99/hr | $2.09/hr |

## The SGLang image (this repo's Dockerfile)

```
docker.io/lmsysorg/sglang:qwen38-27b
docker.io/lmsysorg/sglang@sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1
```

If a platform's image search returns "no data", bypass it: use the full
`docker.io/` prefix or the digest-pinned form in a custom-image field, or build
from this repo's Dockerfile.

## Files
- `Dockerfile` — FROM the pinned SGLang image (for build-from-repo platforms)
- `RUNPOD_RUNBOOK.md` — full ops runbook: commands, persistence layers, gotchas
- `pod.sh` — status/stop/start/rebuild automation (RunPod)
- `DEPLOYMENT_PLAN.md` — original architecture plan (RTX 6000 / SGLang era)

Secrets live only in an uncommitted `.env.runpod` (see `.env.example`).
