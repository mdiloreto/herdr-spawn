#!/usr/bin/env bash
# Usage: lane-stop-check.sh
# Each harness's stop hook runs this (hooks/ for Claude Code and Codex, adapters/ for OpenCode and oh-my-pi) and
# blocks the stop with what it prints; no output lets the session stop. Checking state in one script keeps the
# roles the same in every harness.
# A lane (LANE_MODE set) ends each stretch of work by reporting done or escalating, so it may not stop while its
# lane_state is still working. A coordinator may not stop while one of its lanes waits on its answer. Working
# lanes never hold a coordinator: waiting idle for notices is its normal state, and the watcher wakes it.
# After three blocks in a row the stop goes through and the watcher's stopped notice takes over, rather than
# spinning the agent. The count starts over when the lane's lane_report token changes (lane.sh, including a
# coordinator's reply, sets a fresh one), so this script keeps the only file and lanes write none.
# In the Herdr app (HC_TERMINAL_ID set, no HERDR_ENV) the state is in herdr-core labels and there is no watcher,
# so the lane's last let-through sends the coordinator the stopped notice itself.
set -uo pipefail

app=
if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  pane=$HERDR_PANE_ID
  command -v herdr >/dev/null || exit 0
elif [ -n "${HC_TERMINAL_ID:-}" ]; then
  pane=$HC_TERMINAL_ID app=1
  command -v hc >/dev/null || exit 0
else
  exit 0
fi
command -v jq >/dev/null || exit 0
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
count=$state/stopblock-${pane//[!A-Za-z0-9_-]/_}

reason='' report=-
if [ -n "${LANE_MODE:-}" ]; then
  if [ -n "$app" ]; then
    read -r st report < <(hc get "$pane" --json 2>/dev/null |
      jq -r '.labels | "\(.lane_state // "-") \(.lane_report // "-")"') || st=-
  else
    read -r st report < <(herdr agent get "$pane" 2>/dev/null |
      jq -r '.result.agent.tokens | "\(.lane_state // "-") \(.lane_report // "-")"') || st=-
  fi
  [ "$st" != working ] ||
    reason="You are a lane and have not reported yet. If your goal's done criterion holds and you verified it, write the full report in your reply, then run: $dir/lane.sh done \"<one-line summary>\". If you are blocked on something only your coordinator can decide, write the full question with options and your recommendation, then run: $dir/lane.sh escalate \"<one-line summary>\". Otherwise keep working toward the goal."
else
  # The waiting lanes' reports are the count's key, so a new escalation gets fresh blocks.
  if [ -n "$app" ]; then
    lanes() {
      local t
      for t in $(hc ls --json --label "lane_of=$pane" --label lane_state=escalated 2>/dev/null | jq -r '.terminals[].address'); do
        hc get "$t" --json 2>/dev/null
      done | jq -s '[.[] | {name: (.name // .address), tokens: .labels}]'
    }
  else
    lanes() { herdr agent list 2>/dev/null | jq --arg c "$pane" '[.result.agents[] | select(.tokens.lane_of == $c and .tokens.lane_state == "escalated")]'; }
  fi
  read -r report waiting < <(lanes | jq -r '
    "\(map("\(.name):\(.tokens.lane_report // "-")") | join(",") | if . == "" then "-" else . end) \(map(.name) | join(", "))"') ||
    report=- waiting=''
  [ -z "$waiting" ] ||
    reason="Lanes waiting on your answer: $waiting. Answer each with: $dir/lane.sh reply <lane> \"<answer>\". Ask the human first only if the decision is critical and was never settled."
fi

if [ -z "$reason" ]; then rm -f "$count"; exit 0; fi
{ read -r n last <"$count"; } 2>/dev/null || n=0
[ "${last:-}" = "$report" ] || n=0
if [ "$n" -ge 3 ]; then
  # Herdr app, a lane's first let-through: no watcher will notice, so tell the coordinator once.
  if [ -n "$app" ] && [ -n "${LANE_MODE:-}" ] && [ "$n" -eq 3 ] && [ -n "${LANE_COORDINATOR:-}" ]; then
    echo "4 $report" >"$count"
    name=$(hc get "$pane" --json 2>/dev/null | jq -r '.name // .address') || name=$pane
    detach='nohup'
    if command -v setsid >/dev/null; then detach=setsid; fi
    "$detach" "$dir/lane.sh" _deliver "$LANE_COORDINATOR" \
      "[lane $name] stopped without reporting done or escalating. Check it: hc read $name --lines 120; nudge it with: $dir/lane.sh reply $name \"<what to do next>\"" \
      >/dev/null 2>&1 </dev/null &
  fi
  exit 0
fi
mkdir -p "$state"
echo "$((n + 1)) $report" >"$count"
printf '%s\n' "$reason"
