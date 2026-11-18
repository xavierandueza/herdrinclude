# herdrinclude

A [Herdr](https://herdr.dev) plugin that prepares new git worktrees. When Herdr
creates a worktree, from the sidebar or with `herdr worktree create`, it:

1. Copies the gitignored files listed in `.worktreeinclude` into the new
   checkout, following [Claude Code's rule](https://code.claude.com/docs/en/worktrees#copy-gitignored-files-into-worktrees).
2. Runs the source repository's `.worktreesetup` script inside the new checkout.

A fresh checkout only has tracked files, so local config such as `.envrc` or
`.env` is missing and nothing is installed or trusted yet. This plugin fixes
both.

## `.worktreeinclude`

Put it at the repository root. It uses `.gitignore` syntax:

```text
.envrc
.env.local
```

A file is copied only if it matches a pattern **and** is gitignored. Tracked
files, files under `node_modules/`, and files that already exist in the new
checkout are left alone.

## `.worktreesetup`

An executable script at the repository root. It runs after the copy step:

- the working directory is the new checkout
- `WORKTREE_SOURCE` is the main checkout's path

An untracked `.worktreesetup` (gitignored or listed in `.git/info/exclude`)
always runs. A committed one is code from anyone who can push to the repo, so it
only runs when the repository is listed in `trusted-repos` in the plugin's
config directory (`herdr plugin config-dir xavierandueza.herdrinclude`):

```text
# One main checkout per line; ~ expands to $HOME.
~/projects/backend
/srv/work/frontend
```

List the main checkout, not a worktree: the hook always runs the main
checkout's `.worktreesetup`.

Example: trust the copied `.envrc` and build the nix-direnv cache, so the new
pane has its dev shell straight away.

```bash
#!/usr/bin/env bash
set -euo pipefail
direnv allow .
direnv exec . true
```

```bash
chmod +x .worktreesetup
echo .worktreesetup >> .git/info/exclude
```

The hook fails, and Herdr logs the failure, when the script exits non-zero.

## Install

```bash
herdr plugin install xavierandueza/herdrinclude
```

Or link a local clone:

```bash
herdr plugin link /path/to/herdrinclude
```

Requires Herdr >= 0.7.0, `bash`, `git`, and `jq`.

## Troubleshooting

Each run logs the event payload, every copied file, and the setup output:

```bash
herdr plugin log list --plugin xavierandueza.herdrinclude
```

Worktrees created outside Herdr (`git worktree add`, `claude --worktree`) do not
trigger the hook.

## Tests

```bash
test/run.sh
```

## License

MIT
