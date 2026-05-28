#!/usr/bin/env bash
# Detect potential leakage of personal info, credentials, or local-machine
# state before it reaches the public repository. Designed to be cheap enough
# to run on every commit AND complete enough to be the last line of defence
# in CI.
#
# Detection categories (severity in parentheses):
#   - Committer identity allowlist (fail)             - existing
#   - History author allowlist (fail, --ci only)      - existing
#   - Backup tag presence (fail, --ci only)           - ADR-0004
#   - Absolute home / tailnet paths (fail)            - existing
#   - (a) Content email allowlist (fail)              - ADR-0006
#   - (b) Phone numbers JP / +81 / +1 (fail)          - ADR-0006
#   - (c) JP postal / US street addresses (fail)      - ADR-0006
#   - (d) Mailmap-derived names (fail, auto)          - ADR-0006 (revised PR-A)
#       Plus heuristic full-name patterns (warn)
#   - (e) Internal / corporate domains (warn)         - ADR-0006
#   - (f) Credential file basenames (fail)            - ADR-0006
#   - (g) Forbidden filename meta-defense (fail)      - ADR-0006 (revised PR-A)
#   - (h) Required files presence (fail, --ci only)   - ADR-0008 (fool-proof)
#   - (i) Required .gitignore patterns (fail, --ci only) - ADR-0008 (fool-proof)
#   - (#NN) PR-style references (warn, --ci only)     - ADR-0005
#
# fail-safe (ADR-0008): trap ERR + 必須設定ファイル不在を fail に変更 (silent
# skip 防止)。grep 失敗は明示的に handle、script 異常終了時の violations カウント
# を保証する。
#
# Modes:
#   --pre-commit   Scan staged diff + verify committer identity (default)
#   --ci           Scan entire tree + verify all historical committer emails
#                  + backup tag presence + (#NN) warn
#   --all          Scan entire tree (no history / backup tag check)
#
# Exit codes:
#   0  no violations
#   1  one or more violations detected
#   2  invocation error
#
# Bypass (use sparingly, only for genuine false positives):
#   git commit --no-verify
set -euo pipefail

# fail-safe (ADR-0008): trap unexpected ERR and print a clear stderr message
# so that a silently-failing script still produces a visible signal. Without
# this, `set -e` causes the script to exit without explanation when a deep
# function fails on a non-obvious line.
trap 'rc=$?; printf >&2 "\nFATAL: check-leakage.sh exited unexpectedly (rc=%d) at line %s. The most recent command was: %s\n" "$rc" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}"; exit "$rc"' ERR

# ADR-0015: friendly error helper (loaded best-effort).
_LEAK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_LEAK_SCRIPT_DIR/_friendly-error.sh" ]; then
  # shellcheck disable=SC1091
  source "$_LEAK_SCRIPT_DIR/_friendly-error.sh"
fi

MODE="${1:---pre-commit}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ============================================================================
# CONFIGURATION
# ============================================================================

# --- Committer identity allowlist (commit-time check) ----------------------
ALLOWED_EMAIL_PATTERNS=(
  '^[0-9]+\+[A-Za-z0-9_-]+@users\.noreply\.github\.com$'
  '^[A-Za-z0-9_-]+@users\.noreply\.github\.com$'
)

# --- Content email allowlist (ADR-0006 (a) — file content scan) ------------
# Emails found in tracked file content must match one of these or fail.
# Distinct from ALLOWED_EMAIL_PATTERNS which applies to committer identity.
ALLOWED_CONTENT_EMAIL_PATTERNS=(
  '@users\.noreply\.github\.com$'
  '^noreply@github\.com$'
  '@example\.(com|org|net)$'
  '@localhost$'
  '^user@host$'
  '^name@example'
  '@anthropic\.com$'
  '^[a-z]+@.*\.test$'
  '^you@your-domain'
)

# --- Forbidden content patterns (regex|description) ------------------------
# Detected by line-scan. Pattern hit -> violation (unless line matches
# ALLOWLIST_LINE_REGEXES or file is in SELF_REFERENTIAL_FILES).
## Delimiter note: each entry is `<regex>||<description>`. Two pipes are
## used because several patterns contain literal `|` (regex alternation
## like `(St|Ave|...)`) which would otherwise be eaten by `${entry%%|*}`.
FORBIDDEN_PATTERNS=(
  '\.ts\.net||Tailscale tailnet hostname (private network identifier)'
  '/Users/[a-z][a-z0-9_-]+/||macOS absolute home path (use ~ or $HOME)'
  '/home/[a-z][a-z0-9_-]+/||Linux absolute home path (use ~ or $HOME)'
  'C:\\\\Users\\\\[A-Za-z][A-Za-z0-9_-]+\\\\||Windows absolute home path (use $env:USERPROFILE)'
  # ADR-0006 (b) — phone numbers
  '0[789]0[-[:space:]][0-9]{4}[-[:space:]][0-9]{4}||Japanese mobile phone (070/080/090)'
  '\+81[-[:space:]]?[0-9]{1,4}[-[:space:]]?[0-9]{3,4}[-[:space:]][0-9]{4}||International JP phone (+81)'
  '\+1[-[:space:]]?[0-9]{3}[-[:space:]]?[0-9]{3}[-[:space:]]?[0-9]{4}||North American phone (+1)'
  # ADR-0006 (c) — addresses
  '〒[[:space:]]?[0-9]{3}[-[:space:]]?[0-9]{4}||Japanese postal code'
  '[0-9]{4,5}[[:space:]]+[A-Z][a-z]+[[:space:]]+(St|Ave|Rd|Blvd|Dr|Ln)([^a-zA-Z]|$)||US street address (heuristic)'
)

# --- Internal / private domain patterns (ADR-0006 (e), warn only) ----------
## Same `||` delimiter convention as FORBIDDEN_PATTERNS above.
INTERNAL_DOMAIN_PATTERNS=(
  '\.co\.jp([^a-z0-9]|$)||.co.jp domain'
  'internal\.[a-z0-9.-]+||internal.* subdomain'
  'corp\.[a-z0-9.-]+||corp.* subdomain'
  'intra\.[a-z0-9.-]+||intra.* subdomain'
  'vpn\.[a-z0-9.-]+||vpn.* subdomain'
  '[a-z0-9-]+\.atlassian\.net||Atlassian (Jira/Confluence) Cloud subdomain'
  '[a-z0-9-]+\.slack\.com||Slack workspace subdomain'
)

# --- Credential file basename patterns (ADR-0006 (f), fail when tracked) ---
CREDENTIAL_FILE_BASENAME_PATTERNS=(
  '^\.env$'
  '^\.env\.[^.]+$'
  '\.pem$'
  '\.key$'
  '\.jks$'
  '\.keystore$'
  '\.p12$'
  '\.pfx$'
  '^local\.properties$'
  '^google-services\.json$'
  '^GoogleService-Info\.plist$'
  '^secrets\.ya?ml$'
  '^credentials\.json$'
  '^id_rsa(\.pub)?$'
  '^id_ed25519(\.pub)?$'
  '^id_ecdsa(\.pub)?$'
)

# Filename suffixes that mean "this is a template, not real credentials"
CREDENTIAL_FILE_ALLOW_SUFFIX=(
  '.example'
  '.template'
  '.dist'
  '.sample'
)

# Lines that hit a forbidden pattern but match any of these are considered
# placeholders / documentation examples and ignored.
ALLOWLIST_LINE_REGEXES=(
  '<username>'
  '<user>'
  '<your[-_a-zA-Z]+>'
  '\$env:USERPROFILE'
  '\$HOME'
  '~/'
  '/Users/<'
  '/home/<'
  'example\.com'
  # ADR-0006 — phone/address placeholders
  'XXX-XXXX'
  'XXX-XXX-XXXX'
  '000-0000-0000'
  '000-000-0000'
  '〒XXX-XXXX'
  '\+81-XX-XXXX-XXXX'
  '\+1-XXX-XXX-XXXX'
)

# Files that legitimately contain pattern strings for testing / documentation
# of this very mechanism. Skipped during content scans (all categories).
SELF_REFERENTIAL_FILES=(
  '.mailmap'
  '.gitleaks.toml'
  'scripts/check-leakage.sh'
  '.github/workflows/leak-scan.yml'
  'CONTRIBUTING.md'
  'CHANGELOG.md'
  # ADR-0006 / ADR-0005 documentation paths
  'docs/security.md'
  'docs/architecture.md'
  'docs/persona.md'
  'docs/profile-master.md'
  'source/rules/common/security-mobile.md'
  'source/rules/common/durable-references.md'
  'docs/adr/0005-durable-cross-references.md'
  'docs/adr/0006-pii-detection-policy.md'
  'docs/adr/0007-apply-orchestration.md'
  'docs/adr/0008-fail-safe-and-fool-proof.md'
  'docs/adr/0009-maturity-roadmap.md'
  'docs/adr/0010-quality-gates-automation.md'
  'docs/adr/0011-dependency-automation.md'
  'docs/adr/0012-host-aware-guard.md'
  'docs/adr/0013-environment-reproducibility.md'
  'docs/adr/0014-session-time-budget.md'
  'docs/adr/0015-onboarding-and-runbooks.md'
  'docs/incidents/2026-05-23-backup-tag-leak.md'
  'docs/error-codes.md'
  'docs/runbooks/README.md'
  'docs/runbooks/deploy.md'
  'docs/runbooks/rollback.md'
  'docs/runbooks/incident-response.md'
  'docs/runbooks/oncall-handoff.md'
  'docs/runbooks/postmortem.md'
  # PR-U'' / ADR-0028: ADO adopter PII scrub runbook が PII 検出パターンを
  # 自記述する性質上 (*.ts.net 例示等)、leak-scan が自己 trigger するため
  # self-referential 化する。test も同 runbook の構造を検証する過程で同パターンを
  # docstring 内に引用するため同様に self-referential 化。
  'docs/runbooks/ado-adopter-pii-scrub.md'
  'tests/test_ado_runbook.py'
  'tests/test_leak_prevention.py'
  'tests/test_durable_references.py'
  'tests/test_pii_detection.py'
  'tests/test_defense_layers.py'
  'tests/test_apply_orchestration.py'
  'tests/test_host_guard.py'
  'tests/test_devcontainer.py'
  'tests/test_session_time_budget.py'
  'tests/test_phase4_continuation.py'
  'tests/test_runbook_completeness.py'
  'scripts/apply-to-project.sh'
  'scripts/apply-to-project.ps1'
  'scripts/_host-detect.sh'
  'scripts/session-state.sh'
  'scripts/_friendly-error.sh'
  'scripts/_friendly-error.ps1'
  '.git-host-allowlist'
  'skills/session-time-budget/SKILL.md'
  'scheduled-tasks/session-cleanup-watch/SKILL.md'
  'skills/apply-dev-templates/SKILL.md'
  'templates/apply-presets/leak-only.yml'
  'templates/apply-presets/full.yml'
  'templates/apply-presets/rules-only.yml'
  'templates/apply-presets/quality-only.yml'
  'templates/apply-presets/dependency-only.yml'
  'tests/test_quality_gates.py'
  'tests/test_dependency_automation.py'
  'scripts/check-quality.sh'
  'pyproject.toml'
  'skills/repo-migration-audit/SKILL.md'
  'skills/repo-recreate/SKILL.md'
  # PR-R / ADR-0025 / ADR-0026: persona files contain IT term examples and
  # heuristic name patterns ("Pull Request" matches Cap+lower+SP+Cap+lower).
  'docs/glossary.md'
  'docs/adr/0025-persona-driven-multi-mode.md'
  'docs/adr/0026-japanese-first-writing-style.md'
  'personas/README.md'
  'personas/engineer/PERSONA.md'
  'personas/engineer/style-guide.md'
  'personas/engineer/glossary.md'
  'personas/manufacturing/PERSONA.md'
  'personas/manufacturing/style-guide.md'
  'personas/manufacturing/glossary.md'
  'personas/manufacturing/README.md'
  'tests/test_persona_structure.py'
  'tests/test_apply_persona_flag.py'
  'tests/test_apply_persona_prompt.py'
  'tests/test_adopters_yaml.py'
  'tests/test_glossary_consistency.py'
)

# ============================================================================
# STATE
# ============================================================================

violations=0
pii_warns=0
DERIVED_DENIED_NAMES=()

# ============================================================================
# UTILITIES
# ============================================================================

is_self_referential() {
  local f="$1"
  for sr in "${SELF_REFERENTIAL_FILES[@]}"; do
    [ "$f" = "$sr" ] && return 0
  done
  return 1
}

email_allowed() {
  local email="$1"
  for pat in "${ALLOWED_EMAIL_PATTERNS[@]}"; do
    if printf '%s' "$email" | grep -qE "$pat"; then
      return 0
    fi
  done
  return 1
}

email_allowed_in_content() {
  local email="$1"
  for pat in "${ALLOWED_CONTENT_EMAIL_PATTERNS[@]}"; do
    if printf '%s' "$email" | grep -qE "$pat"; then
      return 0
    fi
  done
  return 1
}

line_allowlisted() {
  local line="$1"
  for allow in "${ALLOWLIST_LINE_REGEXES[@]}"; do
    if printf '%s' "$line" | grep -qE "$allow"; then
      return 0
    fi
  done
  return 1
}

is_credential_file() {
  local f="$1"
  local base
  base="$(basename "$f")"
  # Allow suffix bypass (.env.example, secrets.yml.template, etc.)
  for suf in "${CREDENTIAL_FILE_ALLOW_SUFFIX[@]}"; do
    case "$base" in
      *"$suf") return 1 ;;
    esac
  done
  for pat in "${CREDENTIAL_FILE_BASENAME_PATTERNS[@]}"; do
    if printf '%s' "$base" | grep -qE "$pat"; then
      return 0
    fi
  done
  return 1
}

## Mailmap-derived denied names (ADR-0006 revised, PR-A).
##
## Names that .mailmap normalizes away ARE precisely the names we don't want
## appearing in tracked content. derive_denied_names() computes the set
## difference between raw `%an` and mailmap-applied `%aN`. This makes the
## .mailmap file the single source of truth for "what to detect", removing
## the structural risk of a separate deny-list file (which itself becomes a
## leak surface if it contains the literal names).
##
## Behavior when no .mailmap normalization exists: returns empty set, name
## detection becomes a no-op (graceful degradation, zero false positives on
## a clean fresh clone).
derive_denied_names() {
  comm -23 \
    <(git log --all --format='%an' 2>/dev/null | sort -u) \
    <(git log --all --use-mailmap --format='%aN' 2>/dev/null | sort -u)
}

load_derived_denied_names() {
  DERIVED_DENIED_NAMES=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    DERIVED_DENIED_NAMES+=("$line")
  done < <(derive_denied_names)
}

# ============================================================================
# CHECKS — PER FILE
# ============================================================================

check_content_in_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  is_self_referential "$file" && return 0

  for entry in "${FORBIDDEN_PATTERNS[@]}"; do
    local pat="${entry%%||*}"
    local desc="${entry#*||}"
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      local line="${hit#*:}"
      line="${line#*:}"
      if line_allowlisted "$line"; then
        continue
      fi
      printf '  [%s] %s\n    %s\n' "$file" "$desc" "$hit"
      violations=$((violations + 1))
    done < <(grep -nE "$pat" "$file" 2>/dev/null || true)
  done
}

check_email_content_in_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  is_self_referential "$file" && return 0

  while IFS= read -r email; do
    [ -z "$email" ] && continue
    if email_allowed_in_content "$email"; then
      continue
    fi
    printf '  [%s] non-allowlisted email in content: %s\n' "$file" "$email"
    violations=$((violations + 1))
  done < <(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$file" 2>/dev/null | sort -u)
}

check_internal_domain_in_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  is_self_referential "$file" && return 0

  for entry in "${INTERNAL_DOMAIN_PATTERNS[@]}"; do
    local pat="${entry%%||*}"
    local desc="${entry#*||}"
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      local line="${hit#*:}"
      line="${line#*:}"
      if line_allowlisted "$line"; then
        continue
      fi
      printf '  [warn] %s in %s:\n    %s\n' "$desc" "$file" "$hit"
      pii_warns=$((pii_warns + 1))
    done < <(grep -nE "$pat" "$file" 2>/dev/null || true)
  done
}

check_derived_names_in_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  is_self_referential "$file" && return 0
  [ ${#DERIVED_DENIED_NAMES[@]} -eq 0 ] && return 0

  for name in "${DERIVED_DENIED_NAMES[@]}"; do
    [ -z "$name" ] && continue
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      printf '  [%s] mailmap-derived name found in content: %s\n    %s\n' "$file" "$name" "$hit"
      violations=$((violations + 1))
    done < <(grep -nF "$name" "$file" 2>/dev/null || true)
  done
}

## ADR-0006 (PR-A): heuristic full-name pattern detection. Warn only — false
## positives are expected (every "Pull Request" / "Material Design" matches).
## Capped per file to keep noise manageable.
check_name_patterns_warn() {
  local file="$1"
  [ -f "$file" ] || return 0
  is_self_referential "$file" && return 0

  # English full name candidate: Cap+lower+ SP Cap+lower+. Cap at first 3
  # matches per file to limit noise; full enumeration is not the goal.
  local count_en=0
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    [ "$count_en" -ge 3 ] && break
    local line="${hit#*:}"
    line_allowlisted "$line" && continue
    printf '  [warn] possible full-name pattern (English) in %s: %s\n' "$file" "$hit"
    pii_warns=$((pii_warns + 1))
    count_en=$((count_en + 1))
  done < <(grep -nE '[A-Z][a-z]{2,}[[:space:]]+[A-Z][a-z]{2,}' "$file" 2>/dev/null || true)

  # Kanji full name candidate: 2-4 kanji SP 2-4 kanji.
  # Uses Python for the regex match because:
  #   - GNU grep's POSIX ERE bracket ranges (`[一-龯]`) silently match raw
  #     bytes in C locale (the Ubuntu CI default).
  #   - grep -P with \p{Han} requires UTF-8 locale (Git Bash on Windows
  #     doesn't have it set by default).
  #   - Python re handles Unicode natively, no locale dependency.
  # If python3/python is unavailable, the check silently emits no warns
  # (this is a best-effort heuristic anyway).
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local py
    py="$(command -v python3 || command -v python)"
    local count_jp=0
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      [ "$count_jp" -ge 3 ] && break
      printf '  [warn] possible full-name pattern (Japanese kanji) in %s: %s\n' "$file" "$hit"
      pii_warns=$((pii_warns + 1))
      count_jp=$((count_jp + 1))
    done < <("$py" -c "
import re, sys
pat = re.compile(r'[一-龯]{2,4}\s+[一-龯]{2,4}')
try:
    with open(sys.argv[1], encoding='utf-8', errors='replace') as f:
        for i, line in enumerate(f, 1):
            if pat.search(line):
                print(f'{i}:' + line.rstrip())
except OSError:
    pass
" "$file" 2>/dev/null || true)
  fi
}

# ============================================================================
# CHECKS — REPO LEVEL
# ============================================================================

check_committer_identity() {
  local email
  email="$(git config user.email 2>/dev/null || true)"
  if [ -z "$email" ]; then
    echo "  user.email is not set in git config — refusing to commit"
    violations=$((violations + 1))
    return
  fi
  if ! email_allowed "$email"; then
    echo "  Committer email is not allowlisted: $email"
    echo "    Allowed patterns:"
    for pat in "${ALLOWED_EMAIL_PATTERNS[@]}"; do
      echo "      $pat"
    done
    violations=$((violations + 1))
  fi
}

## ADR-0008 fool-proof: heuristic for "this script is being run against the
## dev-templates repo itself" (vs. a downstream repo that copied check-leakage.sh
## via apply.sh). Required-file invariants only apply to the dev-templates repo.
##
## Heuristic: if `scripts/check-leakage.sh` is in `git ls-files`, this IS a
## dev-templates clone (or fork that maintains the same invariants). Other
## repos using this script via apply.sh will not have it tracked.
is_dev_templates_repo() {
  git ls-files 2>/dev/null | grep -q '^scripts/check-leakage\.sh$'
}

## ADR-0008 (h) — REQUIRED_FILES presence check. --ci only.
check_required_files() {
  is_dev_templates_repo || return 0
  local files
  files="$(git ls-files 2>/dev/null || true)"
  for required in "${REQUIRED_FILES[@]}"; do
    if ! printf '%s\n' "$files" | grep -qxF "$required"; then
      # ADR-0015: emit a friendly_error for downstream readability AND
      # keep the legacy phrasing on stdout (existing tests / scripts grep
      # for "required file is missing"). The friendly version is stderr
      # so the two never collide.
      printf '  required file is missing from tracked tree: %s\n' "$required"
      printf '    -> this file is a load-bearing invariant of dev-templates (ADR-0008).\n'
      printf '       Restore it from git history or re-create. Do not skip this check.\n'
      if declare -F friendly_error >/dev/null 2>&1; then
        friendly_error LEAK_010 \
          "required file is missing from tracked tree: $required" \
          "ADR-0008 fool-proof: 防御層の必須ファイルが削除されると検知が silent skip される可能性がある" \
          "次のいずれか:
    1) git history から復元: git checkout HEAD -- $required
    2) source repo (dev-templates) から再配置:
       bash scripts/apply-to-project.sh --profile leak-only .
    3) 意図的な削除なら ADR を起票してから REQUIRED_FILES から外す" \
          "docs/error-codes.md#leak_010"
      fi
      violations=$((violations + 1))
    fi
  done
}

## ADR-0008 (i) — REQUIRED_GITIGNORE_PATTERNS check. --ci only.
## Each required pattern must appear as an exact line in `.gitignore`.
check_required_gitignore_patterns() {
  is_dev_templates_repo || return 0
  local gi=".gitignore"
  if [ ! -f "$gi" ]; then
    # Covered by check_required_files, but defensive.
    return 0
  fi
  local content
  content="$(cat "$gi" 2>/dev/null || true)"
  for pattern in "${REQUIRED_GITIGNORE_PATTERNS[@]}"; do
    # Match the pattern as a stripped line (allow leading/trailing whitespace
    # tolerance but require exact pattern body).
    if ! printf '%s\n' "$content" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF "$pattern"; then
      printf '  .gitignore is missing required pattern: %s\n' "$pattern"
      printf '    -> ADR-0008 fool-proof: credential file basenames must be ignored\n'
      printf '       by default to prevent accidental tracking. Add the line and commit.\n'
      violations=$((violations + 1))
    fi
  done
}

check_credential_files() {
  local files
  if [ "$MODE" = "--pre-commit" ]; then
    files="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
  else
    files="$(git ls-files 2>/dev/null || true)"
  fi
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_credential_file "$f"; then
      printf '  credential-like file is tracked: %s\n' "$f"
      printf '    -> add to .gitignore, or rename with .example/.template/.dist/.sample suffix\n'
      violations=$((violations + 1))
    fi
  done <<< "$files"
}

## ADR-0006 (PR-A) — meta-defense: filename patterns that must NEVER appear
## in the tracked tree. This protects against accidentally re-introducing
## retired mechanisms (e.g. the `.leak-name-denylist` file from the previous
## ADR-0006 version, which is structurally risky because it would itself
## become a leak surface for the names it lists).
##
## Detection is on the FILENAME ONLY — the file content is never read here,
## avoiding meta-leak from the detection itself.
FORBIDDEN_FILENAMES=(
  'scripts/.leak-name-denylist'
  'scripts/.leak-name-denylist.example'
)

## ADR-0008 fool-proof (h): files that must always be present in the tracked
## tree of this repository. Missing = fail (--ci only). Detection is only
## active when this looks like the dev-templates repo (heuristic: presence of
## scripts/check-leakage.sh itself in tracked files), so other repos using
## this script via apply.sh are not subject to dev-templates' invariants.
REQUIRED_FILES=(
  '.mailmap'
  '.gitleaks.toml'
  '.gitignore'
  '.githooks/pre-commit'
  '.githooks/pre-push'
  'scripts/check-leakage.sh'
  'scripts/setup-hooks.sh'
  'scripts/setup-hooks.ps1'
  '.github/workflows/leak-scan.yml'
  # ADR-0011 Phase 5 self-host: dev-templates 自身が dependabot 設定を持つ
  '.github/dependabot.yml'
  # ADR-0012 host-aware guard: pre-push が source する依存と allowlist
  'scripts/_host-detect.sh'
  '.git-host-allowlist'
  # ADR-0013 environment reproducibility: Codespaces / VS Code Reopen-in-
  # Container entry + CI parity Dockerfile.
  '.devcontainer/devcontainer.json'
  '.devcontainer/Dockerfile'
  '.devcontainer/post-create.sh'
  # ADR-0014 session-time-budget (Phase 4): L2 in-session skill + L3
  # external polling + state CLI + handoff template.
  'skills/session-time-budget/SKILL.md'
  'scheduled-tasks/session-cleanup-watch/SKILL.md'
  'scripts/session-state.sh'
  'docs/sessions/.template.md'
  # ADR-0015 onboarding + friendly errors + runbooks (Phase 4 続編):
  # friendly_error helper (sh + ps1) + 6 runbook files + error-codes
  # catalog.
  'scripts/_friendly-error.sh'
  'scripts/_friendly-error.ps1'
  'docs/error-codes.md'
  'docs/runbooks/README.md'
  'docs/runbooks/deploy.md'
  'docs/runbooks/rollback.md'
  'docs/runbooks/incident-response.md'
  'docs/runbooks/oncall-handoff.md'
  'docs/runbooks/postmortem.md'
  # ADR-0017 Phase 3 cost-observation kit: 5 軸 collector + aggregator +
  # budget template + weekly workflow.
  'scripts/cost-collect-claude.py'
  'scripts/cost-collect-github-actions.sh'
  'scripts/cost-collect-pc-resource.ps1'
  'scripts/cost-collect-runner-uptime.ps1'
  'scripts/cost-report.py'
  'scripts/cost-budget.yml.template'
  '.github/workflows/cost-observation.yml'
  # ADR-0021 Phase 7 delivery predictability collectors.
  'scripts/cost-collect-milestones.py'
  'scripts/cost-collect-release-train.sh'
  # ADR-0022 Phase 8 lead time / DORA 4 metrics collectors.
  'scripts/cost-collect-dora.py'
  'scripts/cost-collect-ci-speed.sh'
  'scripts/cost-collect-pr-review-time.sh'
  # ADR-0024 adoption tracking — backward audit + registry + ledger.
  # PR-R: docs/adopters.txt は docs/adopters.yaml に置換 (host field 追加)。
  'scripts/audit-adopter.py'
  'scripts/audit-all-adopters.sh'
  'docs/adopters.yaml'
  'docs/adopters.md'
  # ADR-0025 persona-driven multi-mode: 必須 2 persona の PERSONA.md
  'personas/engineer/PERSONA.md'
  'personas/manufacturing/PERSONA.md'
)

## ADR-0008 fool-proof (i): `.gitignore` must contain these literal patterns.
## Missing entry = fail (--ci only). Same dev-templates heuristic as above.
## Each entry is matched as a literal line (after trimming whitespace).
REQUIRED_GITIGNORE_PATTERNS=(
  '.env'
  '.env.local'
  '*.pem'
  '*.key'
  '*.jks'
  '*.keystore'
  '*.p12'
  'local.properties'
  'google-services.json'
  'GoogleService-Info.plist'
  # ADR-0010 Phase 2 quality tooling artifacts (coverage / lint cache).
  '.coverage'
  'htmlcov/'
  '.ruff_cache/'
  'coverage.xml'
)

check_forbidden_filenames() {
  local files
  if [ "$MODE" = "--pre-commit" ]; then
    files="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
  else
    files="$(git ls-files 2>/dev/null || true)"
  fi
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    for forbidden in "${FORBIDDEN_FILENAMES[@]}"; do
      if [ "$f" = "$forbidden" ]; then
        printf '  forbidden filename in tracked tree: %s\n' "$f"
        printf '    -> this filename was retired in ADR-0006 (PR-A revision).\n'
        printf '       Name detection now derives the list from .mailmap automatically.\n'
        printf '       See: docs/adr/0006-pii-detection-policy.md\n'
        violations=$((violations + 1))
      fi
    done
  done <<< "$files"
}

# Iterate over a file list and apply all per-file content checks.
scan_files() {
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    check_content_in_file "$f"
    check_email_content_in_file "$f"
    check_internal_domain_in_file "$f"
    check_derived_names_in_file "$f"
    check_name_patterns_warn "$f"
  done
}

# ============================================================================
# MAIN
# ============================================================================

load_derived_denied_names

case "$MODE" in
  --pre-commit)
    check_committer_identity
    check_forbidden_filenames
    check_credential_files
    # Process substitution (not pipe) so scan_files runs in this shell and
    # its mutations to `violations` / `pii_warns` are visible to the parent.
    scan_files < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
    ;;
  --all)
    check_forbidden_filenames
    check_credential_files
    scan_files < <(git ls-files)
    ;;
  --ci)
    # ADR-0008 fool-proof checks (--ci only, dev-templates repo heuristic gated)
    check_required_files
    check_required_gitignore_patterns
    check_forbidden_filenames
    check_credential_files
    scan_files < <(git ls-files)
    while IFS= read -r email; do
      [ -z "$email" ] && continue
      if ! email_allowed "$email"; then
        echo "  History contains non-allowlisted email: $email"
        violations=$((violations + 1))
      fi
    done < <(git log --format='%ae' | sort -u)
    # Backup refs must never reach the public repository — see ADR-0004.
    # Pass the ref namespace as a *prefix* (no trailing glob): for-each-ref's
    # shell-glob `refs/tags/backup/*` only matches one path segment, missing
    # nested paths like `refs/tags/backup/<topic>/<branch>`.
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      echo "  Backup tag must not exist in shared history: $ref"
      violations=$((violations + 1))
    done < <(git for-each-ref --format='%(refname)' 'refs/tags/backup' 2>/dev/null || true)
    # ADR-0005: warn on (#NN) PR-style references in tracked markdown and
    # commit subjects. Skipped for files that *document* the pattern itself.
    pr_ref_warn_skip() {
      case "$1" in
        scripts/check-leakage.sh) return 0 ;;
        tests/test_durable_references.py) return 0 ;;
        tests/test_pii_detection.py) return 0 ;;
        docs/adr/0005-durable-cross-references.md) return 0 ;;
        docs/adr/0006-pii-detection-policy.md) return 0 ;;
        source/rules/common/durable-references.md) return 0 ;;
        CONTRIBUTING.md) return 0 ;;
        CHANGELOG.md) return 0 ;;
        skills/repo-recreate/SKILL.md) return 0 ;;
        skills/repo-migration-audit/SKILL.md) return 0 ;;
        docs/incidents/2026-05-23-backup-tag-leak.md) return 0 ;;
      esac
      return 1
    }
    pr_ref_warns=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      file="${line%%:*}"
      pr_ref_warn_skip "$file" && continue
      echo "  [warn] (#NN) PR-style reference (use SHA/ADR/tag instead — ADR-0005):"
      echo "    $line"
      pr_ref_warns=$((pr_ref_warns + 1))
    done < <(git ls-files '*.md' | xargs grep -nE '\(#[0-9]+\)' 2>/dev/null || true)
    while IFS= read -r subj; do
      [ -z "$subj" ] && continue
      echo "  [warn] (#NN) in commit subject (GitHub squash-merge default — see"
      echo "         ADR-0005 for the (#N)-free override via 'gh pr merge --subject'):"
      echo "    $subj"
      pr_ref_warns=$((pr_ref_warns + 1))
    done < <(git log --format='%h %s' | grep -E '\(#[0-9]+\)' 2>/dev/null || true)
    if [ "$pr_ref_warns" -gt 0 ]; then
      echo ""
      echo "  ($pr_ref_warns informational (#NN) warning(s); not a failure)"
    fi
    ;;
  *)
    echo "Usage: $0 [--pre-commit|--ci|--all]" >&2
    exit 2
    ;;
esac

if [ "$pii_warns" -gt 0 ]; then
  echo ""
  echo "  ($pii_warns informational PII/domain warning(s); not a failure — ADR-0006)"
fi

if [ "$violations" -gt 0 ]; then
  echo ""
  echo "Total violations: $violations"
  echo "If a hit is a legitimate false positive, extend ALLOWLIST_LINE_REGEXES"
  echo "or SELF_REFERENTIAL_FILES in scripts/check-leakage.sh and add a brief"
  echo "justification in the PR."
  echo "Emergency bypass: git commit --no-verify  (use sparingly)"
  exit 1
fi

echo "Leak check passed."
