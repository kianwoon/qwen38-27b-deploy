# Deployment Plan: Qwen3.8-27B (NVFP4) on RunPod → OpenCode Client

**Goal:** Serve Qwen3.8-27B NVFP4 + DSpark with SGLang on a RunPod RTX PRO 6000 Blackwell (96GB), exposed as an OpenAI-compatible API, wired into OpenCode as the coding model. **Targets:** ≥200 tok/s decode @ short context (verified cookbook claim), 130–220 tok/s @ 200k cache-warm; multimodal (image paste) working end-to-end; coding quality within a few % of the BF16/FP8 reference (Phase 5.7 gate, FP8 fallback if not).

---

## 1. Architecture

```
┌─────────────┐  HTTPS/SSE   ┌──────────────────────────┐
│  OpenCode   │ ───────────► │ RunPod HTTP Proxy        │
│  (local Mac)│              │ <pod-id>-30000.proxy.    │
└─────────────┘              │ runpod.net               │
                             └────────┬─────────────────┘
                                      │ :30000
                             ┌────────▼─────────────────┐
                             │ Pod: lmsysorg/sglang:    │
                             │ qwen38-27b               │
                             │ sglang serve (NVFP4)     │
                             │ + Network Volume (HF     │
                             │   cache, persistent)     │
                             └──────────────────────────┘
```

## 2. Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| RunPod product | **Dedicated Pod** (not serverless) | Interactive coding = long-lived streaming sessions; no cold starts mid-session; SSE streaming through RunPod HTTP proxy is reliable. Serverless SGLang worker exists (`runpod-workers/worker-sglang`) but has known 404/streaming friction and ~minutes cold start. |
| GPU | **RTX PRO 6000 Blackwell 96GB only** — $1.69/hr (Community) / $2.09/hr (Secure) | Cheapest validated cookbook cell; 96GB = no concurrency clamping; native Blackwell NVFP4 acceleration. No fallback GPU — availability is managed via DC strategy (§7) instead. |
| Image | `lmsysorg/sglang:qwen38-27b` | Cookbook-pinned image, guaranteed Qwen3.8 support (NVFP4 kernel + parsers). |
| Weights | Network Volume (~50GB), `HF_HOME=/runpod-volume/hf` | 16.5GB NVFP4 + ~8GB DSpark draft (mainline, downloaded first boot) + cache. Volume persists across pod stop/start/rebuild → download once. ~$3.50/mo. |
| Auth | `--api-key` on SGLang (RunPod proxy URL is public) | Single shared secret, passed to OpenCode via env var. |
| Serving tier | `extra_buffer_lazy` (high-throughput) + fp32 SSM | Per cookbook; keep as selected. |

## 3. Final Serve Command (adapted for RunPod)

```bash
HF_HOME=/runpod-volume/hf sglang serve \
  --trust-remote-code \
  --model-path RadixArk/Qwen3.8-27B-NVFP4 \
  --served-model-name qwen3.8-27b \
  --speculative-algorithm DSPARK \
  --speculative-draft-model-path RadixArk/Qwen3.8-27B-DSpark \
  --speculative-draft-attention-backend flashinfer \
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
  --api-key "$SGLANG_API_KEY"
```

Changes vs. cookbook: `--served-model-name qwen3.8-27b` (clean model ID for OpenCode), `--api-key`, `HF_HOME` on the volume, **DSPARK promoted to mainline** (required for the >200 tok/s target — no-spec is bandwidth-bound at ~65-85 tok/s), and `--mamba-full-memory-ratio` retuned for **200k-token coding contexts** (see §6).

---

## 4. Phases

### Phase 0 — Preflight (local, ~10 min)
1. Install CLI: `brew install runpod/runpodctl/runpodctl`
2. `runpodctl doctor` — set API key (from https://runpod.io/console/user/settings) + SSH key
3. `runpodctl gpu list` — confirm RTX PRO 6000 (Blackwell) availability, get exact GPU ID string
4. `runpodctl datacenter list` — survey RTX 6000 stock across **all** DCs **before** creating the volume (network volumes are DC-bound; pod must live in the same DC). Pick the DC with the **deepest current supply**, not merely one card free.
5. `runpodctl user` — check balance

### Phase 1 — Storage (~5 min)
1. Create network volume in the DC chosen in Phase 0.4:
   `runpodctl network-volume create --name qwen38-weights --size 50 --data-center-id <DC_ID>`

### Phase 2 — Pod Provisioning (~10 min)
1. Create a reusable template with the serve command baked in (auto-starts on every pod start):
   ```bash
   runpodctl template create \
     --name qwen38-sglang \
     --image lmsysorg/sglang:qwen38-27b \
     --ports "30000/http" \
     --container-disk-in-gb 60 \
     --volume-in-gb 0 \
     --docker-start-cmd 'HF_HOME=/runpod-volume/hf sglang serve --trust-remote-code --model-path RadixArk/Qwen3.8-27B-NVFP4 --served-model-name qwen3.8-27b --speculative-algorithm DSPARK --speculative-draft-model-path RadixArk/Qwen3.8-27B-DSpark --speculative-draft-attention-backend flashinfer --kv-cache-dtype fp8_e4m3 --mem-fraction-static 0.90 --attention-backend flashinfer --chunked-prefill-size 2048 --reasoning-parser qwen3 --tool-call-parser qwen3_coder --mamba-full-memory-ratio 0.5 --host 0.0.0.0 --port 30000 --mamba-radix-cache-strategy extra_buffer_lazy --mamba-ssm-dtype float32 --api-key $SGLANG_API_KEY'
   ```
2. Launch pod:
   ```bash
   runpodctl pod create \
     --template-id <tpl_id> \
     --gpu-id "<exact string from gpu list>" \
     --name qwen38-27b-sglang \
     --network-volume-id <vol_id> \
     --cloud-type all \
     --env SGLANG_API_KEY=<key>,HF_TOKEN=<token>
   ```
3. First boot: downloads ~24.5GB (16.5GB main + ~8GB DSpark draft) to volume + FlashInfer JIT (~15–25 min, one-time)

### Phase 3 — Verify Server (~5 min)
1. In-pod: `curl localhost:30000/health` → 200; `curl -H "Authorization: Bearer $KEY" localhost:30000/v1/models`
2. External via proxy: same against `https://<pod-id>-30000.proxy.runpod.net`
3. Streaming check: `curl -N ... /v1/chat/completions` with `"stream": true`

### Phase 4 — OpenCode Client Config (~5 min)
1. Add to `~/.config/opencode/opencode.json` (global) or project `.opencode/opencode.json`:
   ```json
   {
     "$schema": "https://opencode.ai/config.json",
     "provider": {
       "qwen38-runpod": {
         "npm": "@ai-sdk/openai-compatible",
         "name": "Qwen3.8-27B @ RunPod",
         "options": {
           "baseURL": "https://<POD_ID>-30000.proxy.runpod.net/v1",
           "apiKey": "{env:SGLANG_API_KEY}"
         },
         "models": {
           "qwen3.8-27b": {
             "name": "Qwen3.8-27B (NVFP4)",
             "capabilities": {
               "tools": true,
               "input": ["text", "image"],
               "output": ["text"]
             },
             "limit": {
               "context": 262144,
               "output": 32768
             }
           }
         }
       }
     },
     "model": "qwen38-runpod/qwen3.8-27b"
   }
   ```
   **`capabilities.input: ["text","image"]` is mandatory** — OpenCode gates image paste client-side on this declaration; without it, pasted screenshots fail with *"this model does not support image input"* even though the server accepts them (confirmed live). `limit.context: 262144` also lets OpenCode enforce the real context budget.
2. `export SGLANG_API_KEY=...` in `~/.zshrc`
3. Per-project override: `"model": "qwen38-runpod/qwen3.8-27b"` in project config, or `opencode --model qwen38-runpod/qwen3.8-27b`

### Phase 5 — Validation (~15 min)
1. Streaming chat completion works end-to-end
2. **Tool-calling round-trip in OpenCode** (critical — OpenCode is tool-heavy; `qwen3_coder` parser must emit/parse tool calls cleanly)
3. Real coding task through a full OpenCode session (edit + bash tools)
4. Note TTFT + decode tok/s as baseline
5. **Performance gates (at realistic context):**
   - Short context (8k): expect **≥200 tok/s** decode (matches verified cookbook claim)
   - Long context (~200k, cache-warm): expect **130–220 tok/s** — record actual; if <130, check DSpark acceptance rate in SGLang logs and KV-pool pressure before touching flags
   - Cache-hit check: second identical-prefix request must show TTFT near-zero (radix hit) — verifies the `extra_buffer_lazy` prefix path works at 200k
6. **Vision round-trip** (model is multimodal; vision tower is enabled by default — no flag needed, checkpoint ships it): curl an `image_url` (base64 data URL) chat completion → model must describe the image. Then paste an image in OpenCode — requires the Phase 4 `capabilities.input: ["text","image"]` declaration (client-side gate; confirmed it blocks without it). If config is set but still blocked → known OpenCode bug, upgrade OpenCode.
7. **Quality gate — NVFP4 vs reference (decision point):** DSpark is verify-then-accept (quality-neutral by construction; A/B-confirm once). NVFP4 risk = compounding noise on long agentic loops. A/B against the known-good reference (Modal H200 BF16/FP8 deployment from `RUNBOOK.md`): ~10 real coding tasks (edit + bash + tool-call JSON compliance, incl. one ~150k-context session) through both; diff outputs. **Ship NVFP4 if task success/format compliance is within a few % of reference; otherwise fall back to FP8 checkpoint (`Qwen/Qwen3.8-27B-FP8`, ~28.5GB, ~100–150 tok/s with DSpark) — same serving stack, one-line swap.**

### Phase 6 — Optimize & Operate (ongoing)
- **DSPARK acceptance tuning** (if long-context decode < target): check acceptance rate in logs; try smaller verify window via `--speculative-dspark-block-size` (default gamma=7 → D=8); lower gamma trades verify overhead for acceptance on long-context/tool-call traffic.
- **HiCache experiment** (only if cache pressure materializes with >6 live agent contexts): host-RAM offload of prefixes/states; GDN-state compatibility unverified — experiment behind a pod restart, not mainline.
- Daily workflow: `runpodctl pod stop <id>` when done / `start` next session (template start-cmd relaunches automatically; weights already on volume → warm boot in ~1–2 min)
- Thinking mode: on by default. If too verbose/slow for coding, set `reasoning_effort` low or disable thinking per-request.

---

## 5. Cost Estimate

| Item | Rate | Monthly (4 hr/day, 22 days) |
|---|---|---|
| RTX PRO 6000 (Community) | $1.69/hr | ~$149 |
| RTX PRO 6000 (Secure) | $2.09/hr | ~$184 |
| Network volume 50GB | ~$0.07/GB/mo | ~$3.50 |
| **Total** | | **~$150–190/mo** |

Spot/interruptible is cheaper but not recommended for interactive sessions.

## 6. Memory Tuning for Long-Context Coding (200k tokens)

Real coding sessions run ~200k context. This inverts the cookbook sizing: KV dominates, GDN state is noise.

**Footprint per 200k context (fp8 KV):** KV ≈ 6.4GB · GDN state (DSpark: S=4 lazy + D=8 = 12 slots) ≈ 1.85GB.
**VRAM budget (0.90 / ratio 0.5):** weights+draft 24.5GB → pool ≈ 62GB → state pool ≈ 21GB (**134 slots ≈ 11 concurrent DSpark agents**) + KV ≈ 41GB (**≈ 6.3 × 200k contexts**, shared system prompt deduped by radix cache).

**`--mamba-full-memory-ratio`** (state pool : KV pool). Formula: `ratio ≈ (S+D) × 153.9MB / (32.8KB × avg_len)`:

| Avg request len | DSpark (S=4, D=8) |
|---|---|
| 8k tokens (cookbook default) | ~6.9 |
| 16k tokens | ~3.4 |
| **200k tokens (this workload)** | **~0.3 → use 0.5** (headroom for agent bursts) |

Validate via SGLang startup logs (max running requests / mamba cache size), adjust once.

**What spare VRAM buys — and doesn't:** more concurrent spec-decoded agents + 1–2 extra cached 200k prefixes (each avoids a 30–60s re-prefill) + OOM margin for D=8 verify batches. It does **not** buy decode speed — that's bandwidth-bound (weights + KV read per step), not memory-bound. The multiplier for *deep* prefix caching is host RAM via HiCache (pods ship 200GB+), not VRAM — see Phase 6.

**Prefix caching = the compute reduction.** SGLang radix cache (on by default) + `extra_buffer_lazy` (checkpoints GDN state at prefix boundaries) → OpenCode's full-history resend each turn hits cache; only new suffix is prefilled. Cold 200k prefill (~30–60s) happens once per fresh session.

**Long-context decode reality:** every decode step reads ~6.4GB KV through the 16 full-attention layers. The verified 200+ tok/s claim is at ISL 8k; at 200k expect **~130–220 tok/s** with DSpark (acceptance-rate dependent). Gate: Phase 5.5.

**Cache-pressure mitigations (in order):** cap concurrent OpenCode agents ≈ 8 · bump `--mem-fraction-static` 0.90 → 0.92 if eviction thrash appears in logs · HiCache host-offload (pods have 200GB+ RAM; dozens of warm 200k states possible) — but GDN-state support is unverified, experiment only.

## 7. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Proxy URL is public | `--api-key` enforced; rotate if leaked |
| SSE streaming issues through proxy | Test early (Phase 3.3); fallback: SSH tunnel `ssh -L 30000:localhost:30000` |
| GPU unavailable in chosen DC | Multi-DC survey upfront (Phase 0.4) + `--cloud-type all` at creation (Community + Secure both count as the pool). Recovery path if a DC dries up while stopped: recreate pod in another DC and re-download ~24.5GB weights (~15–25 min on datacenter links). Cheap insurance — no fallback GPU needed. |
| FlashInfer JIT slow on fresh container | One-time; container disk persists across stop/start |
| Large images vs proxy body limit | Vision requests carry base64 images (1–10MB); if `*.proxy.runpod.net` rejects large bodies → SSH tunnel `ssh -L 30000:localhost:30000` for vision-heavy sessions, or downscale images before paste |
| NVFP4 quality dip on long agentic loops | Phase 5.7 gate: A/B vs Modal H200 BF16/FP8 reference on ~10 real coding tasks; fallback = FP8 checkpoint (`Qwen/Qwen3.8-27B-FP8`), one-line swap, ~100–150 tok/s with DSpark |
| Serverless temptation | Only revisit if usage becomes sporadic/bursty (worker-sglang + flashboot) |

## 8. Rollback / Cleanup

```bash
runpodctl pod delete <pod-id>
runpodctl template delete <tpl_id>
runpodctl network-volume delete <vol_id>   # only if done for good
```
Remove provider block from `opencode.json` + unset `SGLANG_API_KEY`.
