#!/usr/bin/env bash
# Herdr worktree.created hook: copies the files .worktreeinclude selects into the
# new checkout, then runs the source repo's .worktreesetup inside it.
set -uo pipefail

payload="${HERDR_PLUGIN_EVENT_JSON:-}"
if [ -z "$payload" ]; then
  echo "no event payload; nothing to do"
  exit 0
fi
echo "payload=$payload"

# Accepts the event either wrapped in .data or at the top level.
read_field() {
  jq -r "(.data // .) | $1 // empty" <<<"$payload"
}

checkout=$(read_field '.worktree.path // .workspace.worktree.checkout_path')
if [ -z "$checkout" ] || [ ! -d "$checkout" ]; then
  echo "no usable checkout path in payload; nothing to do"
  exit 0
fi

repo_root=$(read_field '.workspace.worktree.repo_root')
if [ -z "$repo_root" ]; then
  common_dir=$(git -C "$checkout" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$common_dir" ]; then
    repo_root=$(dirname "$common_dir")
  fi
fi
if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
  echo "could not find the source repository for $checkout"
  exit 0
fi
if [ "$repo_root" = "$checkout" ]; then
  echo "$checkout is the main checkout; nothing to do"
  exit 0
fi
echo "source=$repo_root checkout=$checkout"

copy_includes() {
  if [ ! -f "$repo_root/.worktreeinclude" ]; then
    echo "no .worktreeinclude; nothing to copy"
    return
  fi

  local copied=0 f
  # Matches .worktreeinclude, untracked, and gitignored: the Claude Code rule.
  while IFS= read -r -d '' f; do
    case "/$f/" in */node_modules/*) continue ;; esac
    if [ -e "$checkout/$f" ]; then
      echo "kept existing: $f"
      continue
    fi
    mkdir -p "$checkout/$(dirname "$f")"
    cp -p "$repo_root/$f" "$checkout/$f"
    echo "copied: $f"
    copied=$((copied + 1))
  done < <(git -C "$repo_root" ls-files -z --others --ignored --exclude-from=.worktreeinclude \
    | git -C "$repo_root" check-ignore -z --stdin)
  echo "copied $copied file(s)"
}

# Lists repos whose committed .worktreesetup may run: one path per line, # comments.
trusted_repos="${HERDR_PLUGIN_CONFIG_DIR:-}/trusted-repos"

is_trusted_repo() {
  if [ -z "${HERDR_PLUGIN_CONFIG_DIR:-}" ] || [ ! -f "$trusted_repos" ]; then
    return 1
  fi
  local repo line resolved
  repo=$(cd "$repo_root" && pwd -P)
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    # Trim leading and trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in \~) line="$HOME" ;; \~/*) line="$HOME/${line#\~/}" ;; esac
    resolved=$(cd "$line" 2>/dev/null && pwd -P) || continue
    if [ "$resolved" = "$repo" ]; then
      return 0
    fi
  done <"$trusted_repos"
  return 1
}

run_setup() {
  local setup="$repo_root/.worktreesetup"
  if [ ! -e "$setup" ]; then
    echo "no .worktreesetup; nothing to run"
    return 0
  fi
  # A committed script is code from whoever can push, so it needs the repo to be trusted.
  if git -C "$repo_root" ls-files --error-unmatch .worktreesetup >/dev/null 2>&1; then
    if ! is_trusted_repo; then
      echo ".worktreesetup is tracked by git and $repo_root is not in $trusted_repos; skipping"
      return 0
    fi
    echo ".worktreesetup is tracked by git; running because $repo_root is trusted"
  fi
  if [ ! -x "$setup" ]; then
    echo ".worktreesetup is not executable; run: chmod +x $setup"
    return 0
  fi
  echo "running .worktreesetup"
  (cd "$checkout" && WORKTREE_SOURCE="$repo_root" "$setup")
}

copy_includes
run_setup
