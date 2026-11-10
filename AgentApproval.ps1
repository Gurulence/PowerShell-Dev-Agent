<#
.SYNOPSIS
    AgentApproval.ps1 - the human-in-the-loop gate.
.DESCRIPTION
    Nothing the model asks for reaches the OS without passing through Request-Approval.
    Modes:
      strict        = every tool call requires explicit Y / N / F / Q (no [A]lways, no Enter default)
      all           = every tool call prompts Y / N / A / F / Q
      readonly-auto = auto-approves read-only inspection tools; prompts on everything else
#>

$script:SessionAllowList = @()

function Test-DenyPattern {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Text
    )

    if (-not $Text) {
        return $null
    }
    foreach ($pat in $script:Cfg.agent.denyPatterns) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        try {
            if ([regex]::IsMatch($Text, $pat, 'IgnoreCase')) {
                return $pat
            }
        }
        catch {
            Write-Verbose -Message "Invalid deny pattern '$pat': $($_.Exception.Message)"
        }
    }
    return $null
}

function Get-CallSummary {
    <#
    .SYNOPSIS
        Produces a human-facing preview of a tool call before execution.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        $ToolArgs
    )

    $sb = [System.Text.StringBuilder]::new()

    switch ($ToolName) {
        'RunCommand' {
            $shell = [string](Get-Arg -ToolArgs $ToolArgs -Name 'shell' -Default 'pwsh')
            $wd = [string](Get-Arg -ToolArgs $ToolArgs -Name 'working_dir' -Default '')
            [void]$sb.AppendLine(('  shell : {0}' -f $shell))
            if ($wd) { [void]$sb.AppendLine(('  cwd   : {0}' -f $wd)) }
            $why = Get-Arg -ToolArgs $ToolArgs -Name 'purpose'
            if ($why) { [void]$sb.AppendLine(('  why   : {0}' -f $why)) }
            [void]$sb.AppendLine('  ---- command ----')
            foreach ($line in ([string](Get-Arg -ToolArgs $ToolArgs -Name 'command' -Default '')).Split("`n")) {
                [void]$sb.AppendLine('  | ' + $line)
            }
        }
        { $_ -in @('RunBuild', 'RunTests', 'DotnetNew', 'AddPackage', 'DotnetSolution', 'DotnetPackPublish', 'NewPsModule', 'TestPsManifest', 'CodeSign', 'RunPwshAnalysis', 'InspectPowerShell') } {
            if ($ToolArgs) {
                foreach ($k in $ToolArgs.Keys) {
                    if ($null -ne $ToolArgs[$k] -and "$($ToolArgs[$k])" -ne '') {
                        [void]$sb.AppendLine(('  {0,-15}: {1}' -f $k, $ToolArgs[$k]))
                    }
                }
            }
        }
        'WriteFile' {
            $path = [string](Get-Arg -ToolArgs $ToolArgs -Name 'path')
            $content = [string](Get-Arg -ToolArgs $ToolArgs -Name 'content' -Default '')
            $old = ''
            try {
                $full = Resolve-AgentPath -Path $path -AllowMissing
                if (Test-Path -LiteralPath $full) {
                    $old = [System.IO.File]::ReadAllText($full)
                }
            }
            catch {
                Write-Verbose -Message "Preview read skipped for '$path': $($_.Exception.Message)"
            }
            [void]$sb.AppendLine((Format-UnifiedDiff -OldText $old -NewText $content -Path $path))
        }
        'EditFile' {
            $path = [string](Get-Arg -ToolArgs $ToolArgs -Name 'path')
            $oldText = [string](Get-Arg -ToolArgs $ToolArgs -Name 'old_text' -Default '')
            $newText = [string](Get-Arg -ToolArgs $ToolArgs -Name 'new_text' -Default '')
            $current = ''
            try {
                $full = Resolve-AgentPath -Path $path
                $current = [System.IO.File]::ReadAllText($full)
            }
            catch {
                Write-Verbose -Message "Preview read failed for '$path': $($_.Exception.Message)"
            }
            $proposed = $current
            if ($current) {
                $norm = $current -replace "`r`n", "`n"
                $needle = $oldText -replace "`r`n", "`n"
                $newNorm = $newText -replace "`r`n", "`n"
                $idx = $norm.IndexOf($needle, [StringComparison]::Ordinal)
                if ($idx -ge 0) {
                    $proposed = $norm.Remove($idx, $needle.Length).Insert($idx, $newNorm)
                }
                else {
                    $pattern = ($needle -split "`n" | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '\s*\n\s*'
                    $m = [regex]::Match($norm, $pattern)
                    if ($m.Success) {
                        $proposed = $norm.Remove($m.Index, $m.Length).Insert($m.Index, $newNorm)
                    }
                }
            }
            [void]$sb.AppendLine((Format-UnifiedDiff -OldText $current -NewText $proposed -Path $path))
        }
        default {
            if ($ToolArgs -and $ToolArgs.Count -gt 0) {
                foreach ($k in $ToolArgs.Keys) {
                    $v = [string]$ToolArgs[$k]
                    if ($v.Length -gt 400) { $v = $v.Substring(0, 400) + '...' }
                    [void]$sb.AppendLine(('  {0}: {1}' -f $k, ($v -replace "`r?`n", "`n  ")))
                }
            }
            else {
                [void]$sb.AppendLine('  (no arguments)')
            }
        }
    }
    return $sb.ToString().TrimEnd()
}

function Read-KeyChoice {
    <#
    .SYNOPSIS
        Reads an explicit single-keystroke decision (or line input when redirected).
    #>
    [CmdletBinding()]
    [OutputType([char])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive approval prompt')]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][char[]]$Allowed,
        [char]$Default = [char]0
    )

    Write-UI -Text $Prompt -Color 'Yellow' -NoNewline

    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($Default -ne [char]0) { return [char]::ToLower($Default) }
            return [char]'n'
        }
        $c = [char]::ToLower($line.Trim()[0])
        if ($Allowed -contains $c) {
            Write-Host -Object $c -ForegroundColor Yellow
            return $c
        }
        return [char]'n'
    }

    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Enter) {
            if ($Default -ne [char]0) {
                Write-UI -Text "$Default`n" -Color 'Yellow'
                return [char]::ToLower($Default)
            }
            continue
        }
        if ($k.Key -eq [ConsoleKey]::Escape) {
            Write-UI -Text "q`n" -Color 'Yellow'
            return [char]'q'
        }
        $c = [char]::ToLower($k.KeyChar)
        if ($Allowed -contains $c) {
            Write-UI -Text "$c`n" -Color 'Yellow'
            return $c
        }
    }
}

function Request-Approval {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive approval prompt displays tool preview')]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [string]$ArgumentsJson,
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Workspace,
        [switch]$AutoApproveYes
    )

    $null = $Registry
    $null = $Workspace

    $argsObj = @{}
    if ($ArgumentsJson -and $ArgumentsJson.Trim()) {
        try {
            $parsed = $ArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 12
            if ($parsed) { $argsObj = $parsed }
        }
        catch {
            Write-Verbose -Message "Could not parse tool arguments JSON for preview: $($_.Exception.Message)"
        }
    }

    # -------- 1. hard deny: NEVER prompt or auto-approve, always refuse ----
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($ToolName)
    foreach ($field in @('command', 'query', 'extra_args', 'path', 'destination')) {
        if (($argsObj.Keys -contains $field) -and $argsObj[$field]) {
            $parts.Add([string]$argsObj[$field])
        }
    }
    $haystack = $parts -join ' '
    $hit = Test-DenyPattern -Text $haystack
    if ($hit) {
        Write-UI -Text "   BLOCKED by deny pattern: $hit" -Color 'Red'
        return [pscustomobject]@{ Decision = 'deny'; Note = "deny-pattern: $hit" }
    }

    # -------- 2. CI smoke-test override (-Yes) -----------------------------
    if ($AutoApproveYes) {
        Write-UI -Text '   auto-approved (-Yes CI flag; deny patterns still active)' -Color 'DarkGray'
        return [pscustomobject]@{ Decision = 'approve'; Note = 'ci-yes-flag' }
    }

    $gate = [string]$script:Cfg.agent.approvalGate

    # -------- 3. tier 0: read-only tools (only when explicitly enabled) ----
    $readOnly = @('ReadFile', 'ListFiles', 'SearchCode', 'GitInfo', 'InspectPowerShell', 'AskUser', 'UpdateTodo')
    if ($gate -eq 'readonly-auto' -and ($readOnly -contains $ToolName)) {
        return [pscustomobject]@{ Decision = 'approve'; Note = 'auto (read-only)' }
    }
    if ($gate -ne 'strict' -and ($script:SessionAllowList -contains $ToolName)) {
        Write-UI -Text "   auto-approved (you allowed '$ToolName' for this session)" -Color 'DarkGray'
        return [pscustomobject]@{ Decision = 'approve'; Note = 'session-allow' }
    }

    # -------- 4. show preview and demand human decision --------------------
    $sep = '-' * 74
    Write-UI -Text $sep -Color 'DarkGray'
    try {
        $summary = Get-CallSummary -ToolName $ToolName -ToolArgs $argsObj
        Write-Host -Object $summary
    }
    catch {
        Write-UI -Text "  (could not build preview: $($_.Exception.Message))" -Color 'DarkRed'
    }
    Write-UI -Text $sep -Color 'DarkGray'

    if ($gate -eq 'strict') {
        $choice = Read-KeyChoice -Prompt '  [Y]es / [N]o / [F]eedback / [Q]uit (strict: explicit key required) ? ' `
            -Allowed ([char[]]@('y', 'n', 'f', 'q'))
    }
    else {
        $choice = Read-KeyChoice -Prompt '  [Y]es / [N]o / [A]lways this tool / [F]eedback / [Q]uit ? ' `
            -Allowed ([char[]]@('y', 'n', 'a', 'f', 'q')) -Default ([char]'y')
    }

    switch ($choice) {
        'y' { return [pscustomobject]@{ Decision = 'approve'; Note = 'user-approved' } }
        'a' {
            $script:SessionAllowList += $ToolName
            Write-UI -Text "   '$ToolName' auto-approved for the rest of this session." -Color 'DarkGray'
            return [pscustomobject]@{ Decision = 'approve'; Note = 'session-allow-new' }
        }
        'n' { return [pscustomobject]@{ Decision = 'deny'; Note = 'user-denied' } }
        'q' { return [pscustomobject]@{ Decision = 'abort'; Note = 'user-aborted' } }
        'f' {
            Write-UI -Text '  feedback > ' -Color 'Magenta' -NoNewline
            $fb = Read-Host
            if (-not $fb) { $fb = 'Try a different approach.' }
            return [pscustomobject]@{ Decision = 'feedback'; Note = $fb }
        }
    }
    return [pscustomobject]@{ Decision = 'deny'; Note = 'unknown-choice' }
}
