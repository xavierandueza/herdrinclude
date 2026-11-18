#!/usr/bin/env bash
# Runs the hook against throwaway repositories and checks what it did.
set -euo pipefail

hook="$(cd "$(dirname "$0")/.." && pwd)/worktree-created.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

git_quiet() { git -c init.defaultBranch=main -c user.name=test -c user.email=test@example.com "$@" >/dev/null 2>&1; }

make_repo() {
  local repo=$1
  mkdir -p "$repo"
  git_quiet -C "$repo" init
  printf '.envrc\n.env\nsecret.txt\nnode_modules/\n.claude/\n' >"$repo/.gitignore"
  echo tracked >"$repo/tracked.txt"
  git_quiet -C "$repo" add .
  git_quiet -C "$repo" commit -m init
  echo 'use flake' >"$repo/.envrc"
  echo 'A=1' >"$repo/.env"
  echo secret >"$repo/secret.txt"
  mkdir -p "$repo/node_modules/pkg"
  echo x >"$repo/node_modules/pkg/.envrc"
  printf '.envrc\n.env\ntracked.txt\n**/.envrc\n' >"$repo/.worktreeinclude"
}

run_hook() {
  HERDR_PLUGIN_CONFIG_DIR=$config_dir HERDR_PLUGIN_EVENT_JSON=$1 bash "$hook" >"$tmp/last.log" 2>&1
}

config_dir="$tmp/config"
mkdir -p "$config_dir"

# Copying and running an untracked setup script.
repo="$tmp/repo"
make_repo "$repo"
git_quiet -C "$repo" worktree add .claude/worktrees/nested -b nested
echo 'nested' >"$repo/.claude/worktrees/nested/.envrc"
cat >"$repo/.worktreesetup" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$PWD" "$WORKTREE_SOURCE" >setup-ran
EOF
chmod +x "$repo/.worktreesetup"
wt="$tmp/wt-a"
git_quiet -C "$repo" worktree add "$wt" -b a
run_hook "{\"data\":{\"workspace\":{\"worktree\":{\"repo_root\":\"$repo\",\"checkout_path\":\"$wt\"}},\"worktree\":{\"path\":\"$wt\"}}}"

check "copies included gitignored files" test -f "$wt/.envrc" -a -f "$wt/.env"
check "skips ignored files not in .worktreeinclude" test ! -e "$wt/secret.txt"
check "skips node_modules" test ! -e "$wt/node_modules"
check "skips nested worktrees" test ! -e "$wt/.claude"
check "leaves tracked files alone" git -C "$wt" diff --quiet
check "runs .worktreesetup in the new checkout" test "$(sed -n 1p "$wt/setup-ran" 2>/dev/null)" = "$wt"
check "passes WORKTREE_SOURCE" test "$(sed -n 2p "$wt/setup-ran" 2>/dev/null)" = "$repo"

# Existing files in the checkout win; repo_root falls back to git.
wt="$tmp/wt-b"
git_quiet -C "$repo" worktree add "$wt" -b b
echo 'mine' >"$wt/.env"
run_hook "{\"worktree\":{\"path\":\"$wt\"}}"
check "keeps files already in the checkout" test "$(cat "$wt/.env")" = mine
check "finds the source repo without repo_root" test -f "$wt/setup-ran"

# A committed setup script only runs in a trusted repo.
repo="$tmp/tracked"
make_repo "$repo"
printf '#!/usr/bin/env bash\ntouch setup-ran\n' >"$repo/.worktreesetup"
chmod +x "$repo/.worktreesetup"
git_quiet -C "$repo" add -f .worktreesetup
git_quiet -C "$repo" commit -m setup
wt="$tmp/wt-c"
git_quiet -C "$repo" worktree add "$wt" -b c
run_hook "{\"data\":{\"worktree\":{\"path\":\"$wt\"}}}"
check "skips a tracked .worktreesetup without trusted-repos" test ! -e "$wt/setup-ran"
check "explains the skip" grep -q 'not in .*trusted-repos' "$tmp/last.log"

printf '# other repos\n%s\n' "$tmp/repo" >"$config_dir/trusted-repos"
wt="$tmp/wt-e"
git_quiet -C "$repo" worktree add "$wt" -b e
run_hook "{\"worktree\":{\"path\":\"$wt\"}}"
check "skips a tracked .worktreesetup in an untrusted repo" test ! -e "$wt/setup-ran"

ln -s "$repo" "$tmp/tracked-link"
printf '%s\n  %s/  # trusted\n' "$tmp/repo" "$tmp/tracked-link" >"$config_dir/trusted-repos"
wt="$tmp/wt-f"
git_quiet -C "$repo" worktree add "$wt" -b f
run_hook "{\"worktree\":{\"path\":\"$wt\"}}"
check "runs a tracked .worktreesetup in a trusted repo" test -f "$wt/setup-ran"
check "says why it ran" grep -q 'is trusted' "$tmp/last.log"

# shellcheck disable=SC2088
echo '~/tracked' >"$config_dir/trusted-repos"
wt="$tmp/wt-g"
git_quiet -C "$repo" worktree add "$wt" -b g
HOME=$tmp run_hook "{\"worktree\":{\"path\":\"$wt\"}}"
check "expands ~ in trusted-repos" test -f "$wt/setup-ran"
rm -f "$config_dir/trusted-repos"

# A failing setup script fails the hook so Herdr logs it.
repo="$tmp/failing"
make_repo "$repo"
printf '#!/usr/bin/env bash\nexit 3\n' >"$repo/.worktreesetup"
chmod +x "$repo/.worktreesetup"
wt="$tmp/wt-d"
git_quiet -C "$repo" worktree add "$wt" -b d
status=0
run_hook "{\"worktree\":{\"path\":\"$wt\"}}" || status=$?
check "returns the setup script's exit status" test "$status" -eq 3

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
