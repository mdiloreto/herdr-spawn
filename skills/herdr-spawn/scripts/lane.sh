#!/usr/bin/env bash
# Usage (in a lane):        lane.sh done "<one-line summary>" | escalate "<one-line summary>" | working
#       (in the coordinator): lane.sh reply <lane-name|pane> "<answer>"
# A lane declares its state in the lane_state pane token (working, done, escalated) instead of the watcher
# guessing it, and only talks to herdr: it writes no files, so no harness sandbox can get in the way. done and
# escalate also set lane_note (the summary on one line, capped at 76 characters plus "..." because herdr cuts a
# token value at 79 silently); every call sets lane_report to a fresh stamp, which is how lanes-watch.sh sees a
# new declaration and queues the notice. reply sends the coordinator's answer to a lane, marks it working again
# and makes sure the coordinator's watcher runs. Needs HERDR_PANE_ID, LANE_COORDINATOR and LANE_MODE in a lane
# (spawn.sh --lane exports the last two).
# In the Herdr app (HC_TERMINAL_ID set, no HERDR_ENV) the state lives in herdr-core terminal labels and there is
# no watcher: done and escalate deliver their notice to the coordinator themselves, once it is idle, and core
# itself tells the coordinator, the lane's parent, when a lane is blocked or exits.
set -euo pipefail

die() { echo "lane.sh: $*" >&2; exit 1; }
usage="usage: lane.sh done \"<one-line summary>\" | escalate \"<one-line summary>\" | working | reply <lane> \"<answer>\""
[ $# -ge 1 ] || die "$usage"
cmd=$1
command -v jq >/dev/null || die "jq is required"
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
app=
if [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then app=1; fi

# One report that re-sends lane_of and lane_mode with the state, so it is correct whether a report merges or
# replaces a source's tokens. Further k=v pairs (lane_note) follow as extra arguments.
set_state() { # <pane> <coordinator> <mode> <state> [k=v ...]
  local pane=$1 of=$2 mode=$3 state=$4 kv
  shift 4
  local pairs=("lane_of=$of" "lane_mode=$mode" "lane_state=$state" "lane_report=$(date +%s)-$$-$RANDOM" "$@")
  if [ -n "$app" ]; then
    hc label "$pane" "${pairs[@]}" >/dev/null || die "could not record lane_state=$state on $pane"
    return
  fi
  local args=()
  for kv in "${pairs[@]}"; do args+=(--token "$kv"); done
  herdr pane report-metadata "$pane" --source herdr-spawn "${args[@]}" >/dev/null ||
    die "could not record lane_state=$state on $pane"
}

# Runs a command in its own session, so it outlives this script and the caller's tool call.
detached() { if command -v setsid >/dev/null; then setsid "$@"; else nohup "$@"; fi; }

# One line, capped so herdr's silent cut at 79 characters shows as "...".
note() {
  local t
  t=$(printf '%s' "$1" | tr '\r\n' '  ')
  if [ ${#t} -gt 79 ]; then t="${t:0:76}..."; fi
  printf '%s' "$t"
}

# Herdr app: types <text> into terminal <t> once its agent is idle or done, so it never lands mid-turn (OpenCode
# drops its reply then) or in a bare shell. Gives up after a day, or when the terminal is gone.
# With a <lane>, the notice is dropped once that lane is no longer working (a stopped notice gone stale).
deliver() { # <t> <text> [<lane>]
  local t=$1 msg=$2 lane=${3:-} st end=$(($(date +%s) + 86400)) since
  while [ "$(date +%s)" -lt "$end" ]; do
    if [ -n "$lane" ] && [ "$(hc get "$lane" --json 2>/dev/null | jq -r '.labels.lane_state // "-"')" != working ]; then return 0; fi
    st=$(hc get "$t" --json 2>/dev/null | jq -r 'if .state != "live" then "gone" else (.status.state // "none") end') || st=gone
    case $st in
      gone) return 0 ;;
      idle) hc send --if idle "$t" "$msg" >/dev/null 2>&1 && return 0 ;;
      "done") hc send "$t" "$msg" >/dev/null 2>&1 && return 0 ;;
    esac
    since=$SECONDS
    hc wait "$t" --timeout 300 >/dev/null 2>&1 || true
    # A blocked agent or a bare shell returns at once: check back every 30 s, not in a tight loop.
    if [ $((SECONDS - since)) -lt 5 ]; then sleep 30; fi
  done
}

case $cmd in
  done|escalate)
    [ $# -eq 2 ] && [ -n "$2" ] || die "$usage"
    ;;
  working) [ $# -eq 1 ] || die "$usage" ;;
  reply) [ $# -eq 3 ] && [ -n "$3" ] || die "$usage" ;;
  _deliver) [ -n "$app" ] && [ $# -ge 3 ] || die "$usage"; deliver "$2" "$3" "${4:-}"; exit 0 ;;
  *) die "$usage" ;;
esac

if [ "$cmd" = reply ] && [ -n "$app" ]; then
  lane=$2
  info=$(hc get "$lane" --json 2>/dev/null) && [ "$(jq -r .state <<<"$info")" = live ] || die "no live terminal $lane"
  read -r term of mode st < <(jq -r '"\(.address) \(.labels.lane_of // "-") \(.labels.lane_mode // "-") \(.status.state // "none")"' <<<"$info")
  [ "$of" != - ] || die "$lane is not a lane (no lane_of label)"
  [ "$of" = "$HC_TERMINAL_ID" ] || die "$lane is $of's lane, not yours"
  # A lane whose agent exited is a bare shell: the answer would run as a command.
  [ "$st" != none ] || die "$lane has no running agent (its agent exited); read it with: hc read $lane"
  set_state "$term" "$of" "$mode" working
  # hc send refuses a blocked agent; the lane's labels go back as they were.
  if ! hc send "$term" "$3" >/dev/null; then
    hc label "$term" "lane_state=$(jq -r '.labels.lane_state // ""' <<<"$info")" \
      "lane_report=$(jq -r '.labels.lane_report // ""' <<<"$info")" "lane_note=$(jq -r '.labels.lane_note // ""' <<<"$info")" >/dev/null || true
    die "send to $lane was refused (blocked?); its state is unchanged"
  fi
  exit 0
fi

if [ "$cmd" = reply ]; then
  lane=$2
  info=$(herdr agent get "$lane") || die "no agent $lane"
  read -r pane of mode < <(jq -r '.result.agent | "\(.pane_id) \(.tokens.lane_of // "-") \(.tokens.lane_mode // "-")"' <<<"$info")
  [ "$of" != - ] || die "$lane is not a lane (no lane_of token)"
  [ -z "${HERDR_PANE_ID:-}" ] || [ "$of" = "$HERDR_PANE_ID" ] || die "$lane is $of's lane, not yours"
  # Working first, so the watcher never sees the answered lane as still escalated or done; undone if the prompt fails.
  set_state "$pane" "$of" "$mode" working
  if ! herdr agent prompt "$lane" "$3" >/dev/null; then
    herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$of" --token "lane_mode=$mode" \
      --token "lane_state=$(jq -r '.result.agent.tokens.lane_state // ""' <<<"$info")" \
      --token "lane_report=$(jq -r '.result.agent.tokens.lane_report // ""' <<<"$info")" \
      --token "lane_note=$(jq -r '.result.agent.tokens.lane_note // ""' <<<"$info")" >/dev/null || true
    die "prompt to $lane was rejected (blocked?); its state is unchanged"
  fi
  statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
  mkdir -p "$statedir"
  # The watcher exits at once if one already runs.
  detached "$dir/lanes-watch.sh" "$of" >>"$statedir/watch-${of//[!A-Za-z0-9_-]/_}.log" 2>&1 </dev/null &
  exit 0
fi

if [ -n "$app" ]; then self=$HC_TERMINAL_ID; else self=${HERDR_PANE_ID:-}; fi
[ -n "$self" ] || die "lane.sh $cmd runs inside a lane: neither HERDR_PANE_ID nor HC_TERMINAL_ID is set"
: "${LANE_COORDINATOR:?lane.sh $cmd runs inside a lane: LANE_COORDINATOR is not set (spawn with --lane)}"
: "${LANE_MODE:?lane.sh $cmd runs inside a lane: LANE_MODE is not set (spawn with --lane)}"

case $cmd in
  working) set_state "$self" "$LANE_COORDINATOR" "$LANE_MODE" working ;;
  "done") set_state "$self" "$LANE_COORDINATOR" "$LANE_MODE" "done" "lane_note=$(note "$2")" ;;
  escalate) set_state "$self" "$LANE_COORDINATOR" "$LANE_MODE" escalated "lane_note=$(note "$2")" ;;
esac
case $cmd in
  working) echo "lane.sh: recorded working" ;;
  *) echo "lane.sh: recorded ${cmd/escalate/escalated}; your coordinator gets the notice once it is idle" ;;
esac
[ -n "$app" ] && [ "$cmd" != working ] || exit 0

name=$(hc get "$self" --json | jq -r '.name // .address')
read_cmd="hc read $name --lines 120"
if [ "$cmd" = "done" ]; then
  msg="[lane $name] done: $(note "$2"). Read its report: $read_cmd"
else
  msg="[lane $name] escalation: $(note "$2"). Read the full question: $read_cmd; answer with: $dir/lane.sh reply $name \"<answer>\""
fi
# Detached so the lane can end its turn while the coordinator is still busy.
detached "$dir/lane.sh" _deliver "$LANE_COORDINATOR" "$msg" >/dev/null 2>&1 </dev/null &
