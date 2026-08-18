#!/bin/bash
# Qwen3.8-27B pod manager — rebuild from template in one command.
# Usage: ./pod.sh [status|stop|start|rebuild [5090|6000]]
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/.env.runpod"

BOLD() { printf '\033[1m%s\033[0m\n' "$*"; }

case "${1:-status}" in

status)
  BOLD "Pod:"; runpodctl pod get "$POD_ID" 2>/dev/null | jq -c '{id, runtimeStatus, costPerHr}'
  BOLD "Health:"; curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" "https://$POD_ID-30000.proxy.runpod.net/health"
  BOLD "Balance:"; runpodctl user 2>/dev/null | jq -c '{clientBalance, currentSpendPerHr}'
  ;;

stop)   # keep the GPU if lucky -> ~90s next start
  runpodctl pod stop "$POD_ID" >/dev/null 2>&1 && echo "⏹  stopped (billing paused). Start again: $0 start"
  ;;

start)  # fastest path — same pod, host may still have GPU + image
  runpodctl pod start "$POD_ID" >/dev/null 2>&1
  echo "▶  starting... waiting for health"
  for i in $(seq 1 20); do sleep 15
    CODE=$(curl -s -m 6 -o /dev/null -w "%{http_code}" "https://$POD_ID-30000.proxy.runpod.net/health" 2>/dev/null)
    echo "  t+$((i*15))s: $CODE"; [ "$CODE" = 200 ] && { echo "✅ UP: https://$POD_ID-30000.proxy.runpod.net/v1"; exit 0; }
  done
  echo "⚠️  not up in 5 min — if the GPU was sniped, run: $0 rebuild"
  ;;

rebuild)  # fresh pod from template + volume (weights stay cached)
  PROFILE="${2:-5090}"
  case "$PROFILE" in
    5090) TEMPLATE_ID="$TPL_5090"; GPU_ID="$GPU_5090"; NAME="qwen38-5090-llamacpp"; DISK=20 ;;
    6000) TEMPLATE_ID="$TPL_6000"; GPU_ID="$GPU_6000"; NAME="qwen38-6000-sglang";  DISK=40 ;;
    *) echo "unknown profile: $PROFILE (use 5090|6000)"; exit 1 ;;
  esac
  BOLD "Rebuilding [$PROFILE] — template $TEMPLATE_ID on $GPU_ID"
  BOLD "Deleting old pod $POD_ID..."
  runpodctl pod delete "$POD_ID" >/dev/null 2>&1
  BOLD "Creating pod (retries stock errors)..."
  NEWID=""
  for i in $(seq 1 8); do
    R=$(runpodctl pod create \
      --template-id "$TEMPLATE_ID" \
      --gpu-id "$GPU_ID" \
      --name "$NAME" \
      --network-volume-id "$VOL_ID" \
      --cloud-type all \
      --ports "30000/http" \
      --container-disk-in-gb "$DISK" 2>&1 | jq -r '.id // empty')
    [ -n "$R" ] && NEWID=$R && break
    echo "  attempt $i: no stock, retrying in 25s..."; sleep 25
  done
  [ -z "$NEWID" ] && { echo "❌ no stock — try later or switch GPU template"; exit 1; }
  sed -i '' "s/POD_ID=.*/POD_ID=$NEWID/" "$DIR/.env.runpod"
  sed -i '' "s|https://[a-z0-9]*-30000.proxy.runpod.net|https://$NEWID-30000.proxy.runpod.net|" ~/.config/opencode/opencode.json
  # A RUNNING OpenCode process caches the provider baseURL in memory and does NOT
  # hot-reload opencode.json — it keeps calling the dead pod ID -> HTTP 404 "Not Found".
  # Restart it so the new endpoint actually takes effect.
  in_opencode=0; pid=$$
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in *OpenCode*|*opencode*) in_opencode=1; break;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  if [ "$in_opencode" = 1 ]; then
    BOLD "⚠️  pod.sh runs inside OpenCode — restart OpenCode now (Cmd+Q, relaunch) or it will keep 404'ing."
  else
    BOLD "Restarting OpenCode to pick up the new endpoint..."
    osascript -e 'quit app "OpenCode"' 2>/dev/null; sleep 3; open -a "OpenCode" 2>/dev/null || true
  fi
  BOLD "Pod $NEWID created. Waiting for health (image pull may take 5-10 min on fresh host)..."
  for i in $(seq 1 25); do sleep 30
    CODE=$(curl -s -m 6 -o /dev/null -w "%{http_code}" "https://$NEWID-30000.proxy.runpod.net/health" 2>/dev/null)
    echo "  t+$((i*30))s: $CODE"; [ "$CODE" = 200 ] && { echo "✅ UP: https://$NEWID-30000.proxy.runpod.net/v1"; exit 0; }
  done
  echo "⚠️  slow boot — check RunPod console logs for the pod"
  ;;
esac
