<#
.SYNOPSIS
    Arena-built agent loop for PowerShell + .NET work. Full-control, strictly gated.
.DESCRIPTION
    A self-contained, dependency-free agent speaking the OpenAI Chat Completions
    protocol (works with OpenAI, Azure OpenAI, Groq, OpenRouter, Ollama, LM Studio,
    and any compatible /v1/chat/completions endpoint).

    Every action the model requests (tool call) is shown with a diff or command preview
    and blocked until you explicitly confirm. Nothing executes silently.
.PARAMETER Task
    The task text. If omitted, you are prompted.
.PARAMETER Mode
    planner | hybrid | executor  (see prompts/modes)
.PARAMETER Workspace
    The project the agent works on. Defaults to the current working directory.
.PARAMETER ConfigPath
    Path to agent.config.json. Defaults to <agent root>/config/agent.config.json
.PARAMETER SessionId
    Session id to resume (e.g. 2026-11-10T09-31-02).
.PARAMETER DryRun
    Show the tool call and approval prompt (or simulate loop) without executing.
.PARAMETER Yes
    Auto-approve tool calls not matched by denyPatterns. Intended ONLY for CI smoke tests.
.PARAMETER NoColor
    Disable ANSI foreground colors.
.EXAMPLE
    ./Agent.ps1 "Add a Pester test for ConvertTo-SqlIdentifier and make it pass"
.EXAMPLE
    $env:OPENAI_API_KEY='sk-...'; ./Agent.ps1 -Mode planner "Design a module for CSV dedup"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,

    [ValidateSet('planner', 'hybrid', 'executor')]
    [string]$Mode,

    [string]$ConfigPath,
    [string]$Workspace,
    [string]$SessionId,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$NoColor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$AgentRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path -Path $AgentRoot -ChildPath 'config/agent.config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath ($AgentRoot)" }

# ---------------------------------------------------------------- libraries ----
. (Join-Path -Path $PSScriptRoot -ChildPath 'AgentConfig.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'AgentLlm.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'AgentTools.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'AgentApproval.ps1')

$Cfg = Read-AgentConfig -Path $ConfigPath
if ($Mode) { $Cfg.agent.mode = $Mode }

$script:Workspace = if ($Workspace) { (Resolve-Path -LiteralPath $Workspace).Path } else { (Get-Location).Path }
$script:Tools = New-AgentToolRegistry
$script:DryRun = [bool]$DryRun
$script:CommandTimeout = [int]$Cfg.agent.commandTimeoutSec
$script:MaxToolOutput = [int]$Cfg.agent.maxToolOutputChars
$script:PlannerTools = @('ReadFile', 'ListFiles', 'SearchCode', 'GitInfo', 'InspectPowerShell', 'UpdateTodo', 'AskUser')

# ---------------------------------------------------------------- UI helpers ---
$script:UseColor = -not $NoColor

function Write-UI {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive agent terminal UI')]
    param(
        [string]$Text,
        [string]$Color = 'Gray',
        [switch]$NoNewline
    )

    if ($script:UseColor) { Write-Host -Object $Text -ForegroundColor $Color -NoNewline:$NoNewline }
    else { Write-Host -Object $Text -NoNewline:$NoNewline }
}

function Write-Banner {
    [CmdletBinding()]
    param()

    $w = 74
    $line = '=' * $w
    Write-UI -Text $line -Color 'DarkCyan'
    Write-UI -Text ("  PS/.NET AGENT  mode={0}  model={1}" -f $Cfg.agent.mode, $Cfg.provider.model) -Color 'Cyan'
    Write-UI -Text ("  workspace: {0}" -f $script:Workspace) -Color 'DarkGray'
    Write-UI -Text ("  approval : {0}  {1}" -f $Cfg.agent.approvalGate, ($(if ($script:DryRun) { '(DRY RUN - nothing executes)' } else { '' }))) -Color 'DarkGray'
    Write-UI -Text $line -Color 'DarkCyan'
}

# ------------------------------------------------------------------ session ----
function New-SessionState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Initializes session directory and metadata object')]
    param([Parameter(Mandatory)][string]$TaskText)

    $id = if ($SessionId) { $SessionId } else { (Get-Date).ToString('yyyy-MM-ddTHH-mm-ss') }
    $dir = Join-Path -Path $script:Workspace -ChildPath $Cfg.agent.sessionDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $logDir = Join-Path -Path $script:Workspace -ChildPath $Cfg.agent.logDir
    if ($Cfg.agent.auditLog) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

    [pscustomobject]@{
        id        = $id
        path      = Join-Path -Path $dir -ChildPath "$id.json"
        auditPath = Join-Path -Path $logDir -ChildPath "audit-$id.jsonl"
        startedAt = (Get-Date).ToString('o')
        task      = $TaskText
        mode      = $Cfg.agent.mode
        messages  = @()
        approvals = @()
        toolCalls = 0
        tokens    = @{ prompt = 0; completion = 0 }
    }
}

function Save-Session {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $Session | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $Session.path -Encoding utf8
}

function Write-AuditEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$EventData
    )

    if (-not $Cfg.agent.auditLog) { return }
    try {
        $EventData['at'] = (Get-Date).ToString('o')
        $line = $EventData | ConvertTo-Json -Compress -Depth 8
        Add-Content -LiteralPath $Session.auditPath -Value $line -Encoding utf8
    }
    catch {
        Write-Verbose -Message "Audit write skipped: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------- prompt ----
function Get-SystemPrompt {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ActiveMode)

    $candidates = @(
        (Join-Path -Path $AgentRoot -ChildPath "prompts/modes/$ActiveMode.md"),
        (Join-Path -Path $script:Workspace -ChildPath ".agent/prompts/modes/$ActiveMode.md"),
        (Join-Path -Path $script:Workspace -ChildPath "prompts/modes/$ActiveMode.md"),
        (Join-Path -Path $PSScriptRoot -ChildPath "../prompts/modes/$ActiveMode.md")
    )
    $modeText = ''
    foreach ($mf in $candidates) {
        if (Test-Path -LiteralPath $mf) {
            $modeText = Get-Content -Raw -LiteralPath $mf
            break
        }
    }

    $core = @'
You are a senior PowerShell and .NET engineer operating inside a gated, auditable agent loop.

## Non-negotiable behaviour
1. You may only affect the world through the provided tools. Never claim you ran something you did not run.
2. Every tool call is reviewed by a human who can approve or reject it. Design each call to be small,
   obvious and independently justifiable. Never bundle unrelated edits into one call.
3. Read before you write. Never edit a file you have not read in this session.
4. Verify with evidence: after writing code, run the build/tests/analysis tools and paste real output.
   If you could not verify something, say so explicitly in your final message.
5. Never guess an API. If unsure whether a cmdlet, type, parameter or overload exists, inspect it
   (InspectPowerShell / Get-Command / dotnet build error) instead of inventing it.
6. No secrets in code, logs, or commands. Use environment variables and mention them by name only.

## PowerShell rules
- Target Windows PowerShell 5.1 AND PowerShell 7+ unless the user says otherwise. Write code that
  parses on 5.1: no `??`, `?.`, `-Parallel`, ternary `? :`, `&&`/`||` chaining, or 7-only operators.
- Use [CmdletBinding()] with SupportsShouldProcess for anything destructive; implement
  Process/End blocks; accept pipeline input where it is natural.
- PSCustomObject over hashtable for output objects; always emit typed, documented output.
- Parameter validation attributes over manual `if (!$x) { throw }` checks.
- No `Write-Host` in library code (use Write-Verbose/Write-Information); `Write-Host` is only for
  interactive UX in end-user scripts.
- Prefer native providers (Test-Path, Get-ChildItem) over spawning external processes.
- Handle errors with -ErrorAction/-ErrorVariable and terminating errors; set $ErrorActionPreference
  deliberately, and restore it in finally.
- Every public function gets comment-based help with .SYNOPSIS .DESCRIPTION .PARAMETER .EXAMPLE .OUTPUTS.

## .NET rules
- Nullable reference types on for new libraries; keep existing projects' settings unchanged.
- async methods end in Async and take a CancellationToken by default.
- No .Result / .Wait() - propagate async, or document why blocking is required.
- IDisposable/IAsyncDisposable implemented correctly; await using for IAsyncDisposable.
- Public API gets XML doc comments; enable GenerateDocumentationFile and keep the build warning-clean.
- Prefer records and init-only setters for immutable DTOs; avoid public fields.
- Keep the build at zero warnings for new projects; do not suppress warnings to make it green.

## Working style
- Work in small verified steps. Announce the step, do it, verify it, move on.
- When you hit an unexpected error, read the actual message and fix the cause, not the symptom.
- If the task is ambiguous, use AskUser instead of guessing.
- Keep your prose in the transcript short. The value is in the tool calls and their output.
'@

    return @"
$core

# Current operating mode: $ActiveMode

$modeText
"@
}

# -------------------------------------------------------------------- tools ----
function Get-ToolSpecList {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$ActiveMode = 'hybrid')

    $specs = foreach ($name in $script:Tools.Keys) {
        if ($ActiveMode -eq 'planner' -and ($script:PlannerTools -notcontains $name)) {
            continue
        }
        $t = $script:Tools[$name]
        [ordered]@{
            type     = 'function'
            function = [ordered]@{
                name        = $name
                description = $t.Description
                parameters  = $t.Parameters
            }
        }
    }
    return @($specs)
}

# ------------------------------------------------------------- tool execute ----
function Invoke-AgentTool {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        $ArgumentsJson,
        [string]$ActiveMode = 'hybrid'
    )

    if (-not $script:Tools.Contains($Name)) {
        return [pscustomobject]@{ ok = $false; output = "ERROR: unknown tool '$Name'." }
    }
    if ($ActiveMode -eq 'planner' -and ($script:PlannerTools -notcontains $Name)) {
        return [pscustomobject]@{ ok = $false; output = "ERROR: tool '$Name' is disabled in planner mode." }
    }

    $argsObj = @{}
    if ($ArgumentsJson -and $ArgumentsJson.Trim()) {
        try {
            $parsed = $ArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 12
            if ($parsed) { $argsObj = $parsed }
        }
        catch {
            return [pscustomobject]@{ ok = $false; output = "ERROR: arguments were not valid JSON: $($_.Exception.Message)" }
        }
    }

    $tool = $script:Tools[$Name]
    try {
        $result = & $tool.Script -ToolArgs $argsObj
        return $result
    }
    catch {
        return [pscustomobject]@{ ok = $false; output = "ERROR in tool '$Name': $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
    }
}

# ------------------------------------------------------------------- main ------
if (-not $Task) {
    Write-Banner
    $Task = Read-Host -Prompt 'Task'
    if (-not $Task) { throw 'No task given.' }
}

Write-Banner
Write-UI -Text "`nTASK: $Task`n" -Color 'White'

$apiKey = Get-AgentSecret -EnvName $Cfg.provider.apiKeyEnv
if (-not $apiKey -and -not $script:DryRun) {
    throw "API key not found in `$env:$($Cfg.provider.apiKeyEnv) or ~/.agent/secrets.xml. Run Install-Agent.ps1, set the env var, or pass -DryRun."
}

$session = New-SessionState -TaskText $Task

# Resume: replay prior messages so the model keeps context.
$history = @()
if ($SessionId -and (Test-Path -LiteralPath $session.path)) {
    $prev = Get-Content -Raw -LiteralPath $session.path | ConvertFrom-Json
    $history = @($prev.messages | Where-Object { $_.role -in @('user', 'assistant', 'tool') })
    Write-UI -Text "Resuming session $SessionId with $($history.Count) prior messages." -Color 'Yellow'
}

$messages = [System.Collections.Generic.List[object]]::new()
$messages.Add(@{ role = 'system'; content = (Get-SystemPrompt -ActiveMode $Cfg.agent.mode) })
foreach ($m in $history) { $messages.Add($m) }
$messages.Add(@{ role = 'user'; content = $Task })

$toolSpecs = Get-ToolSpecList -ActiveMode $Cfg.agent.mode
$turn = 0

while ($turn -lt [int]$Cfg.agent.maxTurns) {
    $turn++
    Write-UI -Text "`n--- turn $turn ---" -Color 'DarkGray'

    try {
        $response = Invoke-ChatCompletion -Config $Cfg -Messages $messages.ToArray() -Tools $toolSpecs -ApiKey $apiKey -DryRun:$script:DryRun
    }
    catch {
        Write-UI -Text "`nMODEL CALL FAILED: $($_.Exception.Message)" -Color 'Red'
        Write-UI -Text "Session saved to $($session.path)" -Color 'DarkGray'
        $session.messages = $messages.ToArray()
        Save-Session -Session $session
        throw
    }

    if (($response.PSObject.Properties.Name -contains 'usage') -and $null -ne $response.usage) {
        if ($response.usage.PSObject.Properties.Name -contains 'prompt_tokens') {
            $session.tokens.prompt += [int]$response.usage.prompt_tokens
        }
        if ($response.usage.PSObject.Properties.Name -contains 'completion_tokens') {
            $session.tokens.completion += [int]$response.usage.completion_tokens
        }
    }

    $msg = $response.choices[0].message
    $text = if ($msg.PSObject.Properties.Name -contains 'content') { $msg.content } else { $null }
    $rawToolCalls = if ($msg.PSObject.Properties.Name -contains 'tool_calls') { $msg.tool_calls } else { $null }
    $toolCalls = @($rawToolCalls | Where-Object { $null -ne $_ })

    if ($text) {
        Write-UI -Text "`n$text" -Color 'White'
    }

    if ($toolCalls.Count -gt 0) {
        $messages.Add(@{
                role       = 'assistant'
                content    = $(if ($text) { $text } else { $null })
                tool_calls = @($toolCalls)
            })
    }
    elseif ($text) {
        $messages.Add(@{ role = 'assistant'; content = $text })
    }

    if ($toolCalls.Count -eq 0) {
        Write-UI -Text "`n=== agent finished (turn $turn) ===" -Color 'Green'
        break
    }

    foreach ($tc in $toolCalls) {
        $name = $tc.function.name
        $argJson = $tc.function.arguments
        $session.toolCalls++

        Write-UI -Text "`n>> TOOL: $name" -Color 'Cyan'

        if ($Cfg.agent.mode -eq 'planner' -and ($script:PlannerTools -notcontains $name)) {
            $verdict = [pscustomobject]@{ Decision = 'deny'; Note = 'blocked-in-planner-mode' }
            Write-UI -Text "   blocked in planner mode ($name)" -Color 'Yellow'
        }
        else {
            $verdict = Request-Approval -ToolName $name -ArgumentsJson $argJson -Registry $script:Tools -Workspace $script:Workspace -AutoApproveYes:$Yes
        }
        $session.approvals += [pscustomobject]@{ at = (Get-Date).ToString('o'); tool = $name; args = $argJson; decision = $verdict.Decision; note = $verdict.Note }

        switch ($verdict.Decision) {
            'approve' {
                if ($script:DryRun) {
                    $result = [pscustomobject]@{ ok = $true; output = '[DRY RUN] Command not executed. Output withheld.' }
                }
                else {
                    $watch = [System.Diagnostics.Stopwatch]::StartNew()
                    $result = Invoke-AgentTool -Name $name -ArgumentsJson $argJson -ActiveMode $Cfg.agent.mode
                    $watch.Stop()
                    $elapsed = $watch.Elapsed.TotalSeconds
                    Write-UI -Text ('   done in {0:N2}s  ({1})' -f $elapsed, $(if ($result.ok) { 'ok' } else { 'failed' })) -Color $(if ($result.ok) { 'Green' } else { 'Red' })
                }
                Write-AuditEvent -Session $session -EventData @{ tool = $name; decision = $verdict.Decision; note = $verdict.Note; ok = $result.ok }
            }
            'deny' {
                $result = [pscustomobject]@{ ok = $false; output = "DENIED BY USER ($($verdict.Note)). Do not retry this exact call. Ask for guidance or propose an alternative." }
                Write-UI -Text '   denied' -Color 'Yellow'
                Write-AuditEvent -Session $session -EventData @{ tool = $name; decision = 'deny'; note = $verdict.Note; ok = $false }
            }
            'abort' {
                Write-AuditEvent -Session $session -EventData @{ tool = $name; decision = 'abort'; note = $verdict.Note; ok = $false }
                Write-UI -Text "`nAborted by user. Session: $($session.path)" -Color 'Yellow'
                $session.messages = $messages.ToArray()
                Save-Session -Session $session
                return
            }
            'feedback' {
                $result = [pscustomobject]@{ ok = $false; output = "USER FEEDBACK (treat as instruction, then adjust): $($verdict.Note)" }
                Write-UI -Text "   feedback sent: $($verdict.Note)" -Color 'Yellow'
                Write-AuditEvent -Session $session -EventData @{ tool = $name; decision = 'feedback'; note = $verdict.Note; ok = $false }
            }
        }

        $out = if ($null -eq $result.output) { '' } else { [string]$result.output }
        if ($out.Length -gt $script:MaxToolOutput) {
            $out = $out.Substring(0, $script:MaxToolOutput) + "`n...[truncated: original $($out.Length) chars]"
        }

        $messages.Add(@{
                role         = 'tool'
                tool_call_id = $tc.id
                content      = $out
            })
    }

    $session.messages = $messages.ToArray()
    Save-Session -Session $session
}

if ($turn -ge [int]$Cfg.agent.maxTurns) {
    Write-UI -Text "`nReached maxTurns ($($Cfg.agent.maxTurns)). Stopping." -Color 'Yellow'
}

$session.messages = $messages.ToArray()
Save-Session -Session $session
Write-UI -Text ("`nSession: {0}" -f $session.path) -Color 'DarkGray'
Write-UI -Text ("Tool calls: {0}   Approvals: {1}   Tokens: {2} prompt / {3} completion" -f `
        $session.toolCalls, $session.approvals.Count, $session.tokens.prompt, $session.tokens.completion) -Color 'DarkGray'
