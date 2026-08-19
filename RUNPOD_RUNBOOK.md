# RunPod Runbook — Qwen3.8-27B (dual GPU profiles)

## Two templates, two profiles

| | **5090** (default) | **6000 Pro** |
|---|---|---|
| Engine | llama.cpp | SGLang |
| Weights | Q5_K_M (18.46GB) | NVFP4 + DFlash 2 draft (3.6GB) |
| Vision (mmproj) | ✅ `--mmproj` | ✅ built-in |
| Speed | ~67 tok/s · 3,600 tok/s prefill | **~145-193 tok/s** @ 110k (DFlash 2 block 5) |
| Concurrency | 4 slots | many (derived from ratio 0.5) |
| Context | 256k (q8_0 KV) | 262k (fp8 KV) |
| Cost | $0.99/hr | $2.09/hr |
| Template | `nvjvyo9up8` | `bjfq916cjh` |
| Rebuild | `./pod.sh rebuild 5090` | `./pod.sh rebuild 6000` |

Both share the same volume (`1xyrwr7b04` — has ALL weight sets cached) and the same
API key / OpenCode provider. Switching GPUs = one rebuild command.

**Note:** 256k context is a 5090-llama.cpp / 6000-SGLang thing. A 5090 SGLang+DFlash2
profile was tried and deleted (32GB caps at ~110k; not worth the profile). If you ever
want DFlash 2 on 5090 again: SGLang image + `--mamba-full-memory-ratio 0.3` +
`--chunked-prefill-size 2048` + block 5 + pinned SHA `25c15d74`.

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
| `1xyrwr7b04` | Volume (EU-RO-1, 50GB) | Q5_K_M + mmproj + NVFP4 + DSpark + DFlash2 weights. Survives everything. **Never delete.** |
| `nvjvyo9up8` | Template `qwen38-5090-llamacpp-v15` | The working llama.cpp recipe (rolling `full-cuda` image). 1-command rebuild. |
| `bjfq916cjh` | Template `qwen38-6000pro-sglang-dflash2` | SGLang NVFP4 + DFlash 2 (block 5, ratio 0.5, chunk 2048, hardened onstart: pip retry + import guard + weight pre-download + restart loop). `./pod.sh rebuild 6000`. |

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

## vast.ai profile (third deployment target)

| | |
|---|---|
| Instance | `48099702` · RTX PRO 6000 WS · **$1.27/hr** (instance ID changes on re-rent; see `.env.runpod`) |
| Template | `567382` · hash `6bf4ab8ebad02a246ace6544f5e174c7` (ssh, `lmsysorg/sglang:qwen38-27b`, 60GB — onstart = **DFlash 2** + auto pip-install SGLang from **pinned commit SHA** `25c15d74` (PR #35462 head) + weight pre-download + retry loops + server restart loop, hardened 2026-08-19; **re-fetch hash after every update**) |
| Access | **SSH tunnel only** (ports don't map on vast ssh instances): see `VAST_TUNNEL` in `.env.runpod` |
| OpenCode | provider `qwen38-vast` → `http://localhost:30000/v1` (tunnel must be up) |
| Vision | ✅ end-to-end verified (image_tokens: 72). Requires: `modalities.input: [text,image]` in opencode.json (NOT capabilities), image-to-text.js plugin allowlists provider, zai vision MCP disabled for qwen agents |
| Config | NVFP4 + **DFlash 2** (`incoai/Qwen3.8-27B-DFlash2`, block 5) · ratio 0.5 · **8192 chunks** — live @ ~110k ctx: accept 0.46-0.90 (avg ~0.65), 145-193 tok/s (beats EAGLE 0.61-0.71 / 104-126 tok/s). **Block 5 > block 8 at long ctx** (sliding-window drafter decays past position 4; shorter block avoids it). **SGLang build**: pinned image lacks DFlash2 + quantized-lm_head fix, so onstart pip-installs from **commit SHA `25c15d74`** (PR #35462 head) — *never* `refs/pull/N/head` (moving ref, deleted on merge = time bomb). **Note:** this model is hybrid linear-attention (3-of-4 layers, `mtp_num_hidden_layers: 1`) — long ctx is NOT KV-bandwidth-bound as a pure transformer would be; only 1/4 layers accumulate KV. **Why 8192**: single-stream workloads; for 2-3 concurrent OpenCode sessions drop to 2048 (each other session's prefill stalls your decode in 8192-token chunks ~600ms each on SM120; 2048 cuts stalls to ~150ms). Bandwidth sharing still applies: @200k ctx per-user decode ≈ 115 (1 user) / 90 (2) / 72 (3) tok/s |
| Weights | instance-local `/root/hf` — template onstart runs `hf download` first (resumable, ~15 min on fresh instance); public repo, HF_TOKEN in env as safety net |

Tunnel: see `VAST_TUNNEL` in `.env.runpod` (host+port change per instance; current: `ssh -p 19702 root@ssh3.vast.ai`).
Debug: `vastai logs <id>`, SSH after `vastai attach ssh <id> ~/.ssh/id_ed25519.pub`.
Note: tunnel dies when Mac sleeps — rerun before using `qwen38-vast`. RunPod proxy has no such dependency.
Restart: `ssh … 'nohup bash /root/restart.sh >> /root/sglang.log 2>&1 &'` — `/root/restart.sh` is idempotent since 2026-08-19 (pkill old server → wait for GPU free → exec new). Local copy in this dir. ⚠️ If you launch it with `> /root/restart.out`, the new server logs there instead of sglang.log — grep both. Restart drops the active sessions' KV cache (next request re-prefills full context, ~10-20s at 40-60k).

### vastai CLI gotchas (learned 2026-08-19, cost a wiped template)

1. **`vastai update template` takes the HASH id, not the numeric id.** `search templates "id eq 567382"` → use its `hash_id`. Numeric id → 400 Bad Request.
2. **The CLI PUT nulls every field you don't pass** (`--name`, `--image`, `--tag`, `--env` …). Always pass ALL fields in one call, or the template gets wiped (this happened: name/image/tag/env went null after a one-flag update).
3. **The template hash changes on every update** — re-fetch `hash_id` from `search templates` before each update.
4. `--ssh` is mandatory on update or runtype silently flips to `args` (docker) and the call 400s.
5. Read: `vastai search templates "id eq 567382" --raw` (query syntax is `field op value`, e.g. `id eq 567382`).

## DFlash 2 — production (2026-08-19)

**Status:** LIVE. DFlash 2 is the default spec method on both vast + RunPod.

### SGLang build requirement

The pinned `lmsysorg/sglang:qwen38-27b` image predates DFlash2. Both templates
(vast 567382, RunPod bjfq916cjh) pip-install SGLang from **commit SHA
`25c15d748b8fa90e00be19595d325fcbf6e8511f`** (PR #35462 head, quantized
lm_head fix) at boot. **Never use `refs/pull/N/head`** — it's a moving ref
deleted on merge (time bomb). The SHA stays valid after merge.

### Open PRs affecting this stack (watchlist, checked 2026-08-19)

| PR | What | Verdict |
|---|---|---|
| **#32052** | GDN recurrent-state commit + `extra_buffer` radix (our exact config) | **Watch.** Bug: cached radix prefixes can carry recurrent state from a different sequence position → prefix-reuse output differs from full prefill (subtle quality/determinism drift, no crash). Unmerged, CI gated, author validation = compile-only. **When it merges: bump both templates' pin to the new main.** Mitigation if needed: `--disable-radix-cache` (loses prefix-cache speedup, ~10-20s re-prefill/turn at 40-60k) |
| #35208 | SWA verify window (sliding-window targets) | N/A — Qwen3.8-27B has `sliding_window: None` (GDN hybrid, no SWA layers) |
| #33531 / #33869 | additive penalties in verify | N/A — no penalties in use |
| #33614 | TP-rank state divergence | N/A — TP=1 |
| #35209 | reject trtllm_mha for DFlash | N/A — flashinfer backend |
| #30119 | modelopt_mixed draft crash | N/A — draft runs unquantized |

Re-check: `curl -s https://api.github.com/repos/sgl-project/sglang/pulls/32052 | jq .merged_at`

### Tuning

| Knob | Value | Why |
|---|---|---|
| `--speculative-num-draft-tokens` | **5** | Block 5 > 8 at long ctx: sliding-window drafter (5 layers) decays past pos 4; shorter block avoids it. Accept 0.65 vs 0.35 at 110k. |
| `--mem-fraction-static` | 0.90 | 20 GB weights + 33 GB KV + 33 GB Mamba on 96 GB |
| `--mamba-full-memory-ratio` | 0.5 | GDN state pool; ~5% used at 1 session. Drop to 0.3 for 2-3 concurrent. |
| `--chunked-prefill-size` | 8192 | Single-stream. Use 2048 for 2-3 concurrent OpenCode sessions. |
| replayssm | **OFF** | `--enable-linear-replayssm-spec` raises `requires-KDA-model` ValueError with DFLASH |

### Measured (RTX PRO 6000, NVFP4, ~110k ctx, single stream)

| Config | Accept rate | Throughput |
|---|---|---|
| No spec | — | ~65-85 tok/s |
| EAGLE/MTP | 0.61-0.71 | ~104-126 tok/s |
| **DFlash 2 block 5** | **0.46-0.90 (avg ~0.65)** | **~145-193 tok/s** |

### Current live instance

- vast `48099702` · ssh3.vast.ai:19702 · $1.07/hr · RTX PRO 6000 WS
- Template `567382` hash `6bf4ab8e` — self-installing, hardened onstart:
  pip retry (5×) → import guard → weight pre-download (3×) → server restart loop (5×)
  → all logged to `/root/sglang.log`
- First boot: ~10-15 min (pip ~3 min + weights if host lacks cache)

## vast.ai instance-creation pitfalls (2026-08-19 saga — 5 failures, 3 causes)

1. **CONSOLE image-tag bug**: console joins template image+tag fields even when
   image already contains the tag → 'repo:tag:tag' or 'repo:tag:null' →
   'invalid reference format'. Fix in template 567382: image='lmsysorg/sglang',
   tag='qwen38-27b' (split fields, nothing doubled). CLI creation handles both layouts.
2. **Dead hosts**: marketplace hosts can die (read-only FS mid-day, registry-unreachable).
   Symptom-respectively: nvidia-ctk 'read-only file system' / 'Get registry-1.docker.io' errors.
   Only fix: destroy + recreate on different offer. Sort offers by reliability > 0.995.
3. **Rescue path without recreate**: `vastai update instance <id> --image "repo:tag"
   --template_hash_id <hash> --onstart "<cmd>"` then `reboot instance` — preserves
   pulled image layers. Used successfully to rescue 48096749.
4. **PREFERRED**: always create via CLI: `TPL=$(vastai search templates "creator_id=653400"
   --raw | jq '.[0].hash_id'); vastai create instance <offer> --template $TPL --disk 60`
