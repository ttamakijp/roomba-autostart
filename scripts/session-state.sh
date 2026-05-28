#!/usr/bin/env bash
# ADR-0014: session-time-budget state management CLI.
#
# Persists per-session end_time + alerts_sent to a single JSON file
# under ~/.cowork/session-time-budget-state.json so that:
#
#   - L2 skill (in-session) and L3 scheduled-task (external polling)
#     share the same view of "which milestone alerts have already been
#     sent for which session"
#   - state survives session crashes (file lives outside the session)
#   - parallel sessions don't corrupt each other (atomic write via
#     mktemp + mv -f)
#
# Usage:
#   scripts/session-state.sh set <session_id> <end_time_iso8601>
#   scripts/session-state.sh get <session_id>             # → end_time | "null"
#   scripts/session-state.sh alert <session_id> <30m|15m|5m|overdue>
#   scripts/session-state.sh alerts <session_id>          # → comma-separated list
#   scripts/session-state.sh complete <session_id>
#   scripts/session-state.sh purge [--older-than <duration>]   # default: 24h
#   scripts/session-state.sh list                          # → human-readable dump
#   scripts/session-state.sh path                          # → absolute state-file path
#
# Exit codes:
#   0  success
#   1  session_id not found (get / alerts) — but no error message; the
#      caller decides whether absence is an error
#   2  invocation error (missing args, bad subcommand, malformed time)
#   3  state file corrupt and could not be auto-recovered

set -euo pipefail

trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then printf >&2 "\nFATAL: session-state.sh exited (rc=%d) at line %s: %s\n" "$rc" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}"; fi; exit "$rc"' ERR

STATE_DIR="${SESSION_STATE_DIR:-$HOME/.cowork}"
STATE_FILE="${SESSION_STATE_FILE:-$STATE_DIR/session-time-budget-state.json}"

usage() {
  sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1; then echo python3
  elif command -v python >/dev/null 2>&1; then echo python
  else
    printf >&2 "ERROR: python is required for JSON manipulation\n"
    exit 2
  fi
}

ensure_state() {
  mkdir -p "$STATE_DIR"
  if [ ! -f "$STATE_FILE" ]; then
    printf '{"sessions": {}}\n' > "$STATE_FILE"
  fi
}

# Read state JSON, run a python edit lambda, write back atomically.
# Args:
#   $1 — python expression evaluated with `data` (the parsed dict) and
#        the positional args $2.. exposed as `argv` (list[str]). The
#        expression must mutate `data` in place; it does not need to
#        return anything.
edit_state() {
  ensure_state
  local expr="$1"; shift
  local py
  py="$(ensure_python)"
  local tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")"
  if ! "$py" - "$STATE_FILE" "$tmp" "$expr" "$@" <<'PYEOF'
import json, sys, os
state_path = sys.argv[1]
tmp_path   = sys.argv[2]
expr       = sys.argv[3]
argv       = sys.argv[4:]
try:
    with open(state_path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    # Corrupt — back up and reset.
    if os.path.exists(state_path):
        try: os.replace(state_path, state_path + ".bak")
        except Exception: pass
    data = {"sessions": {}}

local_ns = {"data": data, "argv": argv}
exec(expr, {}, local_ns)
data = local_ns["data"]
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True)
    f.write("\n")
PYEOF
  then
    rm -f "$tmp"
    printf >&2 "ERROR: failed to edit state file\n"
    exit 3
  fi
  mv -f "$tmp" "$STATE_FILE"
}

# Read-only access — emit a python expression's stdout for `data`.
read_state() {
  ensure_state
  local expr="$1"; shift
  local py
  py="$(ensure_python)"
  "$py" - "$STATE_FILE" "$expr" "$@" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {"sessions": {}}
expr = sys.argv[2]
argv = sys.argv[3:]
local_ns = {"data": data, "argv": argv}
exec(f"_result = {expr}", {}, local_ns)
print(local_ns.get("_result", "") if local_ns.get("_result") is not None else "")
PYEOF
}

require_args() {
  local need="$1"; local got="$2"
  if [ "$got" -lt "$need" ]; then
    printf >&2 "ERROR: missing args (got %d, need %d)\n" "$got" "$need"
    usage >&2
    exit 2
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  set)
    require_args 2 $#
    sid="$1"; end_time="$2"
    # Minimal validation: ISO8601 starts with YYYY-MM-DD or is the
    # literal "null". Anything else is rejected (caller's bug).
    case "$end_time" in
      null|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
      *) printf >&2 "ERROR: end_time must be ISO8601 (YYYY-MM-DD...) or 'null'\n"; exit 2 ;;
    esac
    edit_state '
import datetime
sid, end_time = argv[0], argv[1]
sessions = data.setdefault("sessions", {})
entry = sessions.setdefault(sid, {})
entry["end_time"] = None if end_time == "null" else end_time
entry.setdefault("alerts_sent", [])
entry.setdefault("started_at", datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds"))
entry.setdefault("cleanup_completed", False)
' "$sid" "$end_time"
    ;;

  get)
    require_args 1 $#
    sid="$1"
    out="$(read_state 'data.get("sessions", {}).get(argv[0], {}).get("end_time", "")' "$sid")"
    # Empty output = session not registered → exit 1 (no error message)
    if [ -z "$out" ]; then exit 1; fi
    if [ "$out" = "None" ]; then echo "null"; else echo "$out"; fi
    ;;

  alert)
    require_args 2 $#
    sid="$1"; milestone="$2"
    case "$milestone" in
      30m|15m|5m|overdue) ;;
      *) printf >&2 "ERROR: milestone must be one of: 30m, 15m, 5m, overdue\n"; exit 2 ;;
    esac
    edit_state '
sid, milestone = argv[0], argv[1]
sessions = data.setdefault("sessions", {})
entry = sessions.setdefault(sid, {"end_time": None, "alerts_sent": [], "cleanup_completed": False})
alerts = entry.setdefault("alerts_sent", [])
if milestone not in alerts:
    alerts.append(milestone)
' "$sid" "$milestone"
    ;;

  alerts)
    require_args 1 $#
    sid="$1"
    out="$(read_state '",".join(data.get("sessions", {}).get(argv[0], {}).get("alerts_sent", []))' "$sid")"
    # If session exists but has no alerts, print empty line (rc 0).
    # If session does not exist at all, rc 1.
    if ! read_state 'argv[0] in data.get("sessions", {})' "$sid" | grep -q True; then
      exit 1
    fi
    echo "$out"
    ;;

  complete)
    require_args 1 $#
    sid="$1"
    edit_state '
sid = argv[0]
sessions = data.setdefault("sessions", {})
entry = sessions.setdefault(sid, {"end_time": None, "alerts_sent": [], "cleanup_completed": False})
entry["cleanup_completed"] = True
' "$sid"
    ;;

  purge)
    # Default: drop completed sessions older than 24h.
    older_than="24h"
    while [ $# -gt 0 ]; do
      case "$1" in
        --older-than) older_than="$2"; shift 2 ;;
        --older-than=*) older_than="${1#--older-than=}"; shift ;;
        *) shift ;;
      esac
    done
    # Convert e.g. "24h" / "30m" / "7d" to seconds.
    case "$older_than" in
      *h) sec=$((${older_than%h} * 3600)) ;;
      *m) sec=$((${older_than%m} * 60)) ;;
      *d) sec=$((${older_than%d} * 86400)) ;;
      *)  sec="$older_than" ;;  # raw seconds
    esac
    edit_state '
import datetime
threshold_sec = int(argv[0])
now = datetime.datetime.now(datetime.timezone.utc)
sessions = data.get("sessions", {})
to_drop = []
for sid, entry in sessions.items():
    if not entry.get("cleanup_completed"):
        continue
    started = entry.get("started_at")
    if not started:
        continue
    try:
        s = datetime.datetime.fromisoformat(started)
        if s.tzinfo is None:
            s = s.replace(tzinfo=datetime.timezone.utc)
        if (now - s).total_seconds() > threshold_sec:
            to_drop.append(sid)
    except Exception:
        continue
for sid in to_drop:
    del sessions[sid]
' "$sec"
    ;;

  list)
    ensure_state
    py="$(ensure_python)"
    "$py" - "$STATE_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
sessions = data.get("sessions", {})
if not sessions:
    print("(no sessions tracked)")
else:
    for sid, entry in sorted(sessions.items()):
        end = entry.get("end_time") or "null"
        alerts = ",".join(entry.get("alerts_sent", [])) or "-"
        completed = "yes" if entry.get("cleanup_completed") else "no"
        print(f"  {sid}: end={end}, alerts={alerts}, cleanup={completed}")
PYEOF
    ;;

  path)
    echo "$STATE_FILE"
    ;;

  -h|--help|help|"")
    usage
    [ -z "$cmd" ] && exit 2 || exit 0
    ;;

  *)
    printf >&2 "ERROR: unknown subcommand: %s\n" "$cmd"
    usage >&2
    exit 2
    ;;
esac
