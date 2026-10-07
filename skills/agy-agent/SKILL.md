---
name: agy-agent
description: Delegate a well-specified implementation task (code edits plus build/test runs) to the agy (Antigravity, Gemini) CLI through the guarded wrapper ~/.claude/scripts/agy-delegate.ps1, inside the session's git worktree. Use when the user says "use agy", "delegate to agy/gemini/antigravity", or asks Claude to plan and have agy implement. Do NOT use for design decisions, debugging judgment, deploys, git operations, or anything touching secrets.
---

# agy-agent

Claude plans and reviews; agy implements. agy runs unattended under its own settings
(`~/.gemini/antigravity-cli/settings.json`), so the wrapper is the guardrail. Always go through it.

## The command (PowerShell tool)

```powershell
& "$HOME\.claude\scripts\agy-delegate.ps1" -WorkDir '<abs worktree path>' -PromptFile '<abs task file>'
```

- Never call `agy` directly, and never add `--dangerously-skip-permissions` or `--mode accept-edits`.
- The wrapper's default model is `gemini-3.8-flash-medium`; don't pass `-Model` unless the user asks.
- One run per task file. Pick a mode:
  - **Foreground (short jobs):** leave `-TimeoutMin` at its default of 9 so it fits the 10-minute tool
    timeout, and set the tool `timeout` to 600000.
  - **Background (longer jobs):** run with the PowerShell tool's `run_in_background: true` and pass a
    larger limit, e.g. `-TimeoutMin 30`. Background calls have no 10-minute cap; you are notified when
    the wrapper exits, and its output (summary, git status, diff stat) arrives then. Don't poll or
    sleep while waiting. Keep `-TimeoutMin` set anyway: it is what lets the wrapper detect and flag a
    cut-off run.
  - **Parallel:** only for independent tasks in **separate worktrees** (separate branches). Never run
    two agy runs in the same worktree at once; they would edit over each other.
- Exit codes: agy's own code, or **2 = partial run** (agy hit the time limit mid-turn; the wrapper prints
  a `PARTIAL RUN` line). Exit 0 means agy finished its turn, not that the work is right.
- The wrapper refuses the main checkout, non-worktree folders, and `main`/`master`. If it refuses,
  fix the setup (EnterWorktree, a `feat/…` or `fix/…` branch); don't work around it.
- Built-in hard rules agy always gets: edit only inside the worktree, no state-changing git, no deploy /
  publish / cloud changes, no secrets or env files, no deliberately wrong credentials.

## Before delegating

1. Be in a session worktree on a `feat/…`/`fix/…` branch, set up as the project's own instructions
   require (env files copied, dependencies installed).
2. **Checkpoint:** commit (and push) the current state so agy's changes show up cleanly in `git diff`
   and can be discarded.
3. Write the task file in the scratchpad directory (not the repo). It must stand alone, because agy
   has none of this conversation:
   - **Approval:** agy reads the project's CLAUDE.md/AGENTS.md. If they require a plan to be approved
     before coding and the user has approved it, say so on the first line of the task file (use the
     project's own wording if it defines one). Without that line agy writes a plan and stops.
   - goal and acceptance criteria; exact files (absolute paths) to change and not to change;
   - the project rules that matter for this change, restated (agy may not apply them unprompted);
   - checks to run and report: the project's own type-check, lint and test commands, plus any
     offline verification scripts, and which commands it must NOT run (network, database, servers).

## After it returns

1. Read the summary and the `git status` / `git diff --stat` the wrapper prints, then the full `git diff`.
2. Re-run the checks yourself. Don't trust agy's report alone: it may claim checks it didn't finish.
3. Fix or discard (`git restore` / `git checkout -- <file>` of agy's own uncommitted changes) as needed,
   or send a short correction run. Claude does all git state changes: commit, push, merge.
   - A correction to the run that just finished: add `-Continue`. The wrapper saves each run's agy
     conversation ID per worktree and resumes exactly that one (`agy --conversation <id>`), so agy
     keeps its context and the correction task file can be short (findings + what to change).
     `-ConversationId <id>` resumes a specific one. Never use agy's own `-c`: it resumes the most
     recent conversation, which may be another worktree's task. Start fresh (no `-Continue`) for a
     new task, or when the previous run went badly and its context would mislead.
4. Tell the user what agy did and what you changed or rejected.

## Lessons from use

- **Size:** one 9-minute run handles roughly 25-35 small, careful edits (e.g. replacing types). Bigger
  jobs can go in one background run with a longer `-TimeoutMin`, but smaller runs are easier to
  review and recover from: still split big jobs by file or folder, biggest/riskiest file alone. Put shared rules in one rules file in the
  scratchpad and point each run's task file at it.
- **Partial runs (exit 2):** agy usually stops between edits, but check: type-check, look at the diff,
  checkpoint-commit what is good, then send the remaining files as a new run.
- **Refactors that must not change behaviour:** list the forbidden shortcuts explicitly: casts or
  disable comments to silence errors, new fallback values (`|| ''`, `?? 0`), extra runtime checks,
  changed control flow. Ask it to report mismatches it finds instead of "fixing" them. Then review the
  diff line by line for exactly those patterns; agy reaches for them under pressure.
- **Subtle behaviour changes to look for in review:** error handling rewritten with `instanceof Error`
  (plain-object errors, e.g. from database clients, lose their message), `x || 'fallback'` patterns
  rewritten so the fallback can no longer fire, and `null` silently turned into `undefined` or `''`.
- **Restrict commands in the task file:** agy sometimes starts its own "inspection" scripts that keep a
  process alive (e.g. a PDF library holding node open) and then waits on them until the time limit.
  Put a COMMAND RESTRICTION section at the top of the task file listing the only commands it may run
  (type-check, lint, tests, named verify scripts), each in the foreground under `timeout`, and forbid
  ad-hoc `node -e` / `python -c` exploration: "read code instead".
- **Corrections:** when your own correction instruction is wrong, say so plainly in the next task file
  ("the reviewer's previous instruction was wrong") so agy doesn't defend it.
