# claude-agy-delegate

A [Claude Code](https://claude.com/claude-code) skill plus a guarded PowerShell wrapper that let Claude
**plan and review** while the Google Antigravity CLI (`agy`) **implements**: Claude writes a stand-alone
task file, `agy` edits code and runs the checks inside an isolated git worktree, and Claude reviews the
diff and does every git state change itself.

The guardrails live in the wrapper, not in the prompt, so share and install both files.

## What the wrapper enforces

- Runs only inside a linked git worktree under `.claude\worktrees\<name>` (Claude Code's worktree
  convention), never the main checkout, and never on `main` / `master`.
- Never passes `--dangerously-skip-permissions`; `agy` applies your own
  `~\.gemini\antigravity-cli\settings.json` (toolPermission, trustedWorkspaces).
- Gives `agy` hard rules on every run: edit only inside the worktree, no state-changing git, no deploys
  or cloud changes, never read or print `.env` files or secrets, no deliberately wrong credentials.
- Detects a run cut off by the time limit and exits `2` (partial run).
- Logs the full output and ends with `git status --short` and `git diff --stat` for review.
- Saves each run's `agy` conversation ID per worktree; `-Continue` resumes exactly that conversation
  for a correction run (`agy --conversation <id>`). It never uses `agy -c`, which resumes the most recent
  conversation and could pick up another worktree's task when runs overlap.

## Requirements

- Windows with Windows PowerShell 5.1 (the wrapper is PowerShell; a bash port would be needed elsewhere).
- [Claude Code](https://claude.com/claude-code) and the Antigravity CLI (`agy`) on your `PATH`, signed in.
- git.

## Install

```powershell
git clone https://github.com/nawatw/claude-agy-delegate.git
cd claude-agy-delegate
New-Item -ItemType Directory -Force "$HOME\.claude\skills\agy-agent", "$HOME\.claude\scripts" | Out-Null
Copy-Item skills\agy-agent\SKILL.md "$HOME\.claude\skills\agy-agent\SKILL.md"
Copy-Item scripts\agy-delegate.ps1 "$HOME\.claude\scripts\agy-delegate.ps1"
```

Then restart Claude Code. The skill is available as `agy-agent`; ask Claude to "delegate this to agy".

The default model is `gemini-3.8-flash-medium`. If your account does not have it, edit the `$Model`
default in `agy-delegate.ps1` (see `agy models`) or tell Claude which model to pass with `-Model`.

## Usage (what Claude runs)

```powershell
# New task (foreground, fits Claude Code's 10-minute tool limit)
& "$HOME\.claude\scripts\agy-delegate.ps1" -WorkDir 'D:\Repo\.claude\worktrees\feat-x' -PromptFile 'C:\...\task.md'

# Longer task: run the tool call in the background and raise the limit
& "$HOME\.claude\scripts\agy-delegate.ps1" -WorkDir '...' -PromptFile '...' -TimeoutMin 45

# Correction run in the same agy conversation as the previous run in that worktree
& "$HOME\.claude\scripts\agy-delegate.ps1" -WorkDir '...' -PromptFile 'C:\...\fix.md' -Continue
```

Exit codes: `agy`'s own code, or `2` for a partial run. Exit `0` means `agy` finished its turn, not that
the work is right: the skill tells Claude to read the diff and re-run the checks itself.

## Tips (from real use)

- Commit before delegating, so `agy`'s changes show up cleanly in `git diff` and can be discarded.
- Write the task file so it stands alone: goal, exact files, project rules, and the checks to run.
- List the only commands `agy` may run, each under `timeout`; otherwise it may start its own
  inspection scripts and wait on them until the time limit.
- Run parallel tasks only in separate worktrees.

## Licence

MIT, see [LICENSE](LICENSE).
