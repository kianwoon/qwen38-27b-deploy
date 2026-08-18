# Qwen3.8-27B serving image — SGLang profile (RTX PRO 6000 / Blackwell)
# Base: the SGLang cookbook's pinned image for Qwen3.8-27B (NVFP4 kernels,
# qwen3/qwen3_coder parsers, DSpark, vision tower). 16.6GB.
#
# Digest-pinned equivalent (byte-exact, if a platform rejects tags):
#   docker.io/lmsysorg/sglang@sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1
FROM docker.io/lmsysorg/sglang:qwen38-27b

# Serve command is provided at runtime (see RUNPOD_RUNBOOK.md); nothing to bake in.
# Env expected at launch: HF_HOME, HF_TOKEN, SGLANG_API_KEY
