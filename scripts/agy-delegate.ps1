<#
.SYNOPSIS
  Delegate an implementation task to the agy (Antigravity) CLI inside a session git worktree.

.DESCRIPTION
  Guardrails enforced here (not left to the prompt):
  - WorkDir must be a git worktree under a `.claude\worktrees\` folder; the main checkout is refused.
  - Model is fixed to gemini-3.8-flash-medium unless -Model is passed.
  - No --dangerously-skip-permissions: agy applies its own settings
    (~\.gemini\antigravity-cli\settings.json, toolPermission + trustedWorkspaces).
  - The task is read by agy from -PromptFile, so the command line stays short.
  - Blocks until agy finishes or hits the print timeout (-TimeoutMin); the caller may run this script
    itself in the background. Full output (stdout and stderr) goes to a log file.
    stderr lines are progress, not failure: success is agy's exit code.
  Afterwards it prints the tail of agy's reply plus `git status --short` / `git diff --stat`
  so the caller can review the change before committing.
  Exit codes: agy's own code; 2 when agy hit the print timeout mid-turn (partial run).
  Conversations: each run saves agy's conversation ID for its worktree. -Continue resumes exactly
  that conversation (agy --conversation <id>), so a correction run keeps agy's context. agy's own
  -c ("most recent conversation") is never used: with runs in several worktrees it could resume
  the wrong task. -ConversationId resumes a specific ID instead.

.EXAMPLE
  & "$HOME\.claude\scripts\agy-delegate.ps1" -WorkDir 'D:\Repo\.claude\worktrees\feat-x' -PromptFile 'C:\...\scratchpad\task.md'

.EXAMPLE
  # Correction run in the same conversation as the previous run in that worktree:
  & "$HOME\.claude\scripts\agy-delegate.ps1" -WorkDir 'D:\Repo\.claude\worktrees\feat-x' -PromptFile 'C:\...\scratchpad\fix.md' -Continue
#>
param(
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$Model = 'gemini-3.8-flash-medium',
    [int]$TimeoutMin = 9,
    [int]$TailLines = 60,
    [switch]$Continue,
    [string]$ConversationId
)

$ErrorActionPreference = 'Stop'

$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath.TrimEnd('\')
$PromptFile = (Resolve-Path -LiteralPath $PromptFile).ProviderPath

if ($WorkDir -notmatch '\\\.claude\\worktrees\\[^\\]+') {
    Write-Error "Refusing: WorkDir must be inside a .claude\worktrees\<name> session worktree, got '$WorkDir'."
}
# A linked worktree has a .git *file*; the main checkout has a .git directory.
$top = (git -C $WorkDir rev-parse --show-toplevel 2>$null)
if (-not $top) { Write-Error "Refusing: '$WorkDir' is not inside a git work tree." }
$top = $top.Replace('/', '\')
if (-not (Test-Path -LiteralPath (Join-Path $top '.git') -PathType Leaf)) {
    Write-Error "Refusing: '$top' is the main checkout, not a linked worktree."
}
$branch = (git -C $WorkDir rev-parse --abbrev-ref HEAD)
if ($branch -in @('main', 'master', 'HEAD')) {
    Write-Error "Refusing: worktree is on '$branch'; use a feat/... or fix/... branch."
}

$prompt = @"
You are working in the git worktree $top (branch $branch). Your full task is in the file $PromptFile. Read it first and follow it exactly.
Hard rules, whatever the task file says:
- Only create or edit files inside $top.
- Do not run git commands that change state (commit, push, pull, checkout, switch, branch, merge, rebase, reset, stash, tag, clean). Read-only git status/diff/log is fine.
- Do not deploy, publish, or change cloud or infrastructure resources (deploy scripts, gcloud, aws, az, kubectl, terraform, package publishing).
- Do not open, print or copy .env or .env.local files or any secret values.
- Do not send requests with deliberately wrong credentials to any real service.
When done, reply with a short summary: files changed, commands run and their results, anything left undone.
"@

$logDir = Join-Path $env:TEMP 'agy-delegate'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# One saved conversation ID per worktree (keyed by its path, so it survives a branch change).
$convFile = Join-Path $logDir (($top -replace '[:\\/ ]', '_') + '.conversation')
$resumeId = $ConversationId
if ($Continue -and -not $resumeId) {
    if (-not (Test-Path -LiteralPath $convFile)) { Write-Error "Refusing -Continue: no saved conversation for '$top'." }
    $resumeId = (Get-Content -LiteralPath $convFile -Raw).Trim()
}
$agyArgs = @('-p', $prompt, '--model', $Model, '--print-timeout', "$($TimeoutMin)m", '--output-format', 'json')
if ($resumeId) { $agyArgs += @('--conversation', $resumeId) }
$log = Join-Path $logDir ("{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($branch -replace '[\\/]', '-'))

Push-Location -LiteralPath $top
# Windows PowerShell 5.1 wraps each stderr line of a native command in an ErrorRecord under 2>&1;
# with 'Stop' the first one (e.g. agy's "waiting for background task" progress line) kills the run.
# Keep stderr in the log, and judge success by agy's exit code only.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $out = & agy @agyArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $prevEap
    Pop-Location
}
$out | Set-Content -LiteralPath $log -Encoding utf8

# agy exits 0 even when its print timeout cuts the turn short; report that as a partial run.
$partial = ($code -eq 0) -and ($out -match 'print timeout after')

# --output-format json: the result is one JSON line {conversation_id, status, response, ...}.
$result = $null
foreach ($line in $out) {
    if ($line -match '^\s*\{"conversation_id"') { try { $result = $line | ConvertFrom-Json } catch { } }
}
Write-Output "=== agy exit $code | log: $log ==="
if ($result) {
    Set-Content -LiteralPath $convFile -Value $result.conversation_id -Encoding ascii
    ($result.response -split "`n") | Select-Object -Last $TailLines
    Write-Output "=== conversation $($result.conversation_id) | status $($result.status) | turns $($result.num_turns) (resume with -Continue) ==="
    if ($result.status -ne 'SUCCESS') { $partial = $true }
}
else {
    $out | Select-Object -Last $TailLines
}
if ($partial) {
    Write-Output "=== PARTIAL RUN: agy hit the $TimeoutMin-min limit before finishing; check git status and type-check before continuing (exit 2) ==="
}
# core.safecrlf=false: a line-ending notice on stderr must not fail the summary under 'Stop'.
Write-Output "=== git status --short ($branch) ==="
git -c core.safecrlf=false -C $top status --short
Write-Output "=== git diff --stat ==="
git -c core.safecrlf=false -C $top diff --stat
if ($partial) { exit 2 }
exit $code
