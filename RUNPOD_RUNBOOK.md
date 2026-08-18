# RunPod Runbook — Qwen3.8-27B (dual GPU profiles)

## Two templates, two profiles

| | **5090** (default) | **6000 Pro** |
|---|---|---|
| Engine | llama.cpp | SGLang |
| Weights | Q5_K_M (18.46GB) | NVFP4 + DSpark draft (24.5GB) |
| Vision (mmproj) | ✅ `--mmproj` | ✅ built-in |
| Speed | ~67 tok/s · 3,600 tok/s prefill | **~160 tok/s** (DSpark) |
| Concurrency | 4 slots | many (derived from ratio 0.8) |
| Context | 256k (q8_0 KV) | 262k (fp8 KV) |
| Cost | $0.99/hr | $2.09/hr |
| Template | `g935mzj9pj` | `02w005bkjj` |
| Rebuild | `./pod.sh rebuild 5090` | `./pod.sh rebuild 6000` |

Both share the same volume (`1xyrwr7b04` — has ALL weight sets cached) and the same
API key / OpenCode provider. Switching GPUs = one rebuild command.

## Daily operations

```bash
./pod.sh status    # health + pod + balance
./pod.sh stop      # done for the day (stops billing)
./pod.sh start     # next session — ~90s if the host kept the GPU
./pod.sh rebuild   # GPU was sniped / anything broken — fresh pod from template
```

If `start` shows the RunPod "GPUs no longer available" dialog in the console → click
**"Automatically migrate"** (keeps volume + working config), or run `./pod.sh rebuild`.

## The three persistence layers

| ID | Thing | Role |
|---|---|---|
| `1xyrwr7b04` | Volume (EU-RO-1, 50GB) | Q5_K_M + mmproj + NVFP4/DSpark weights. Survives everything. **Never delete.** |
| `g935mzj9pj` | Template `qwen38-5090-llamacpp-v14` | The working llama.cpp recipe (rolling `full-cuda` image). 1-command rebuild. |
| `ma159tfp4c` | Template `qwen38-5090-sglang` | Backup: SGLang NVFP4+DSpark (~160 tok/s, no vision, 1 concurrent req). |

Pod IDs change on rebuild — `pod.sh` keeps `.env.runpod` + `opencode.json` in sync automatically
AND restarts OpenCode (a running process caches the provider baseURL and does not hot-reload
`opencode.json`; without the restart it 404s "Not Found" against the dead pod ID).

## OpenCode

Provider `qwen38-runpod` → model `qwen3.8-27b` (global config, auto-repointed by pod.sh).
Image input is enabled. Thinking lands in `reasoning_content` (collapsible in OpenCode).

## Gotchas learned the hard way

1. **Never edit the start command via web UI** — it double-wraps (`bash -c bash -c ...`) and silently exits. Use templates.
2. **`runpodctl --docker-start-cmd` splits on COMMAS**, not spaces: `bash,-c,<command>`.
3. **HF rate-limits by DC IP range** (Iceland 429'd even with token; Romania/NL are fine).
4. **Stopping releases the GPU** — stock is "Low", so it may get sniped. Migrate or rebuild; weights never re-download.
5. Rolling `full-cuda` tag can drift (flags renamed twice this session). If a rebuild fails on a flag error, compare `llama-server --help` in pod logs, or pin the image via console → pod → **Commit to Image** and point the template at it.
6. Vision requires `--mmproj` (today's builds support it); MTP/spec is SGLang-only.
7. **After a rebuild, OpenCode must be restarted** — it caches the provider baseURL in memory
   and does not hot-reload `opencode.json`. The old pod ID is deleted, so the RunPod proxy
   answers **404 "Not Found"** for every message until the restart. `pod.sh rebuild` now
   handles this automatically (or warns you if it's running inside OpenCode itself).

## Files

- `.env.runpod` — all IDs/keys (SGLANG_API_KEY, VOL_ID, POD_ID, TEMPLATE_ID, GPU_ID, HF_TOKEN)
- `pod.sh` — operations script
- `DEPLOYMENT_PLAN.md` — original plan (RTX 6000/SGLang era; superseded by this runbook for 5090/llama.cpp)
