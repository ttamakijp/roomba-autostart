#!/usr/bin/env bash
# ADR-0015: friendly error helper (source-able library).
#
# Standardizes error output across dev-templates scripts so a downstream
# user always gets the same shape:
#   ❌ エラー [<code>]
#   何が起きたか: ...
#   なぜ:        ...
#   どう直すか:   ...
#   詳しく:       docs/error-codes.md#<code>   (optional)
#
# Usage (from another script):
#   source "$(dirname "$0")/_friendly-error.sh"
#   friendly_error LEAK_001 \
#     ".gitignore に .env が含まれていません" \
#     "credentials が誤って commit されるリスク" \
#     "scripts/apply-to-project.sh --profile leak-only を実行" \
#     "docs/error-codes.md#leak_001"
#
# Or print to a file descriptor other than stderr:
#   FRIENDLY_ERROR_FD=1 friendly_error ...
#
# Args:
#   $1 — code (e.g. LEAK_001). Must match `[A-Z]+_[0-9]+`.
#   $2 — what happened (1 sentence, observable)
#   $3 — why it matters (1 sentence, consequence)
#   $4 — how to fix (1-3 lines, copy-paste-ready command preferred)
#   $5 — optional doc path / anchor for deeper context

# Guard against double-source.
if [ -n "${_FRIENDLY_ERROR_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_FRIENDLY_ERROR_LOADED=1

friendly_error() {
  local code="${1:-OPS_000}"
  local what="${2:-(detail unavailable)}"
  local why="${3:-(reason unavailable)}"
  local fix="${4:-(no automated fix available; see docs/error-codes.md)}"
  local doc="${5:-}"
  local fd="${FRIENDLY_ERROR_FD:-2}"

  # Validate code shape (warning only — we still print the error).
  case "$code" in
    [A-Z]*_[0-9]*) ;;
    *) printf >&"$fd" "[friendly_error] WARN: code '%s' does not match <PREFIX>_<NNN>\n" "$code" ;;
  esac

  {
    printf '\n❌ エラー [%s]\n' "$code"
    printf '\n何が起きたか:\n  %s\n' "$what"
    printf '\nなぜ:\n  %s\n' "$why"
    printf '\nどう直すか:\n  %s\n' "$fix"
    if [ -n "$doc" ]; then
      printf '\n  詳しく: %s\n' "$doc"
    fi
    printf '\n'
  } >&"$fd"
}

# Helper: emit a friendly_error AND exit with the given code.
friendly_die() {
  local rc="$1"; shift
  friendly_error "$@"
  exit "$rc"
}
