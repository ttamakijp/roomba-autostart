#!/usr/bin/env bash
# ADR-0012: host detection helpers (source-able library).
#
# This file is BOTH source-able and directly executable:
#   - Sourced: provides `detect_host`, `detect_host_from_url`, `check_allowlist`
#   - Executed: calls `detect_host` and prints the result to stdout
#
# Source from another script:
#   source "$(dirname "$0")/_host-detect.sh"
#   host=$(detect_host)
#
# Or call as subprocess (returns the detected host on stdout):
#   host=$(bash scripts/_host-detect.sh)
#
# Detected hosts:
#   github         — github.com (SSH or HTTPS)
#   azure-devops   — dev.azure.com (modern) or *.visualstudio.com (legacy)
#   gitlab         — gitlab.com or gitlab.* (self-hosted GitLab is heuristic)
#   bitbucket      — bitbucket.org
#   unknown        — any other URL, or no origin remote

# Detect the host category from a remote URL string. Pure helper, no git calls.
# Usage: detect_host_from_url "<url>"
detect_host_from_url() {
  local url="$1"
  if [ -z "$url" ]; then
    echo "unknown"
    return 0
  fi
  if [[ "$url" =~ github\.com[:/] ]]; then
    echo "github"
  elif [[ "$url" =~ dev\.azure\.com[:/] ]] || [[ "$url" =~ \.visualstudio\.com[:/] ]]; then
    echo "azure-devops"
  elif [[ "$url" =~ gitlab\.com[:/] ]] || [[ "$url" =~ gitlab\. ]]; then
    echo "gitlab"
  elif [[ "$url" =~ bitbucket\.org[:/] ]]; then
    echo "bitbucket"
  else
    echo "unknown"
  fi
}

# Detect host of the current working repository's `origin` remote.
# Returns: github | azure-devops | gitlab | bitbucket | unknown
detect_host() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  detect_host_from_url "$remote_url"
}

# Convert a remote URL to a normalized "<host>/<owner>/<repo>" form for
# matching against the .git-host-allowlist patterns.
#
# Examples:
#   git@github.com:ttamakijp/dev-templates.git           -> github.com/ttamakijp/dev-templates
#   https://github.com/ttamakijp/dev-templates.git       -> github.com/ttamakijp/dev-templates
#   https://dev.azure.com/myorg/myproj/_git/myrepo       -> dev.azure.com/myorg/myproj/_git/myrepo
#   git@gitlab.com:group/sub/repo.git                    -> gitlab.com/group/sub/repo
normalize_url() {
  local url="$1"
  # SCP-like SSH form: git@host:owner/repo
  if [[ "$url" =~ ^[A-Za-z0-9_-]+@([A-Za-z0-9.-]+):(.+)$ ]]; then
    url="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  # Strip protocol prefix
  url="${url#https://}"
  url="${url#http://}"
  url="${url#git://}"
  url="${url#ssh://}"
  # Strip git@ user component for ssh:// URLs that survived above
  url="${url#git@}"
  # Strip trailing .git
  url="${url%.git}"
  # Strip trailing slash
  url="${url%/}"
  echo "$url"
}

# Test whether the given URL matches at least one pattern in the allowlist.
# Allowlist patterns are shell globs (case-sensitive), one per non-comment line.
# Returns 0 if matched (or allowlist file is absent — permissive), 1 if not matched.
#
# Usage: check_allowlist <url> [<allowlist-file>]
#   default allowlist-file: .git-host-allowlist
check_allowlist() {
  local url="$1"
  local allowlist_file="${2:-.git-host-allowlist}"
  # Permissive when the file is absent — newly-cloned repos shouldn't be
  # locked out before the maintainer has had a chance to write the allowlist.
  [ -f "$allowlist_file" ] || return 0
  local normalized
  normalized="$(normalize_url "$url")"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    # Skip comments and blank lines.
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    # Bash glob match (case '$normalized' in $line) does NOT auto-expand
    # globs in the case-pattern when stored in a variable, but inside `case`
    # statement the right-hand glob does expand. Use that.
    # shellcheck disable=SC2254
    case "$normalized" in
      $line) return 0 ;;
    esac
  done < "$allowlist_file"
  return 1
}

# If executed directly (not sourced), run detect_host and print the result.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  detect_host
fi
