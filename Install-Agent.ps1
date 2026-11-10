<#
.SYNOPSIS
    Installs the PS/.NET agent kit (both VS Code Copilot Custom Agents + standalone Agent.ps1) into a project folder.
.DESCRIPTION
    Copies the standalone agent runtime into <Project>/.agent, installs native VS Code Copilot
    Custom Agents, skills, instructions, prompts, and safety hooks into <Project>/.github,
    installs/merges <Project>/.vscode settings, tasks, launch, MCP server, and extension
    recommendations (adjusting script paths to .agent/), updates .gitignore and .editorconfig,
    and optionally stores a BYOK API key securely in ~/.agent/secrets.xml (DPAPI on Windows).
.PARAMETER Project
    Target project folder. Defaults to the current directory.
.PARAMETER ApiKey
    Optional BYOK API key (only needed if using standalone Agent.ps1; Copilot in VS Code uses GitHub sign-in).
.PARAMETER StoreKey
    persist = save to ~/.agent/secrets.xml (default when providing key)
    session = only set $env: for this session
    skip    = do not ask for a key (recommended if using GitHub Copilot in VS Code)
.PARAMETER Force
    Replace existing .vscode/*, .github/*, and .editorconfig files (creating *.bak-<timestamp> backups first).
.EXAMPLE
    ./Install-Agent.ps1 -Project C:\src\MyLib
.EXAMPLE
    ./Install-Agent.ps1 -Project C:\src\MyLib -StoreKey skip
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer UI')]
param(
    [string]$Project = (Get-Location).Path,

    [string]$ApiKey,

    [ValidateSet('persist', 'session', 'skip')]
    [string]$StoreKey = 'skip',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$KitRoot = $PSScriptRoot

function ConvertTo-ProtectedSecret {
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param([Parameter(Mandatory)][string]$PlainText)

    $secure = [System.Security.SecureString]::new()
    foreach ($ch in $PlainText.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function Write-InstallStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    Write-Host -Object "  * $Text" -ForegroundColor Cyan
}

function Write-InstallDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    Write-Host -Object "    $Text" -ForegroundColor DarkGray
}

function Write-InstallWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    Write-Host -Object "    ! $Text" -ForegroundColor Yellow
}

function Copy-WithBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Stamp,
        [string]$ContentOverride,
        [switch]$ForceOverwrite
    )

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $writeAction = {
        param($targetPath)
        if ($null -ne $ContentOverride) {
            [System.IO.File]::WriteAllText($targetPath, $ContentOverride, [System.Text.UTF8Encoding]::new($false))
        }
        else {
            Copy-Item -LiteralPath $Source -Destination $targetPath -Force
        }
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        & $writeAction $Destination
        return 'installed'
    }
    elseif ($ForceOverwrite) {
        Copy-Item -LiteralPath $Destination -Destination "$Destination.bak-$Stamp" -Force
        & $writeAction $Destination
        return 'replaced'
    }
    else {
        & $writeAction "$Destination.agent-kit"
        return 'preserved'
    }
}

Write-Host -Object ''
Write-Host -Object 'PS/.NET AGENT - INSTALLER' -ForegroundColor White
Write-Host -Object ('=' * 60) -ForegroundColor DarkCyan
Write-Host -Object "  from : $KitRoot"
Write-Host -Object "  into : $Project"
Write-Host -Object ''

if (-not (Test-Path -LiteralPath $Project)) { throw "Project folder does not exist: $Project" }
$Project = (Resolve-Path -LiteralPath $Project).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($Project -eq $KitRoot) {
    Write-InstallWarning -Text 'Target project is the kit repository itself; skipping self-copy into .agent/.'
}
else {
    # ------------------------------------------------------------ 1. .agent ----
    Write-InstallStep -Text 'Installing standalone agent & tools into .agent/'
    $agentDir = Join-Path -Path $Project -ChildPath '.agent'
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null

    $payload = @(
        'Agent.ps1',
        'AgentConfig.ps1',
        'AgentLlm.ps1',
        'AgentTools.ps1',
        'AgentApproval.ps1',
        'agent-doctor.ps1',
        'config/agent.config.json',
        'config/agent.config.schema.json',
        'prompts/modes/planner.md',
        'prompts/modes/hybrid.md',
        'prompts/modes/executor.md',
        'tools/Invoke-AgentPester.ps1',
        'tools/New-EnterprisePsModule.ps1',
        'tools/New-EnterpriseDotnetSolution.ps1',
        'tools/PsDotnetMcpServer.ps1',
        'tools/Sign-Artifact.ps1',
        'tests/AgentTools.Tests.ps1',
        'tests/DenyPatterns.Tests.ps1',
        'tests/AgentLoop.Tests.ps1'
    )

    foreach ($rel in $payload) {
        $src = Join-Path -Path $KitRoot -ChildPath $rel
        if (-not (Test-Path -LiteralPath $src)) {
            Write-InstallWarning -Text "missing in kit, skipped: $rel"
            continue
        }
        $dst = Join-Path -Path $agentDir -ChildPath $rel
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        if ($PSCmdlet.ShouldProcess($dst, 'copy')) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    }
    Write-InstallDetail -Text "agent files installed in $agentDir"

    # ------------------------------------------------------------ 2. .github ---
    Write-InstallStep -Text 'Installing GitHub Copilot Custom Agents, skills, instructions, prompts & hooks'
    $ghSrc = Join-Path -Path $KitRoot -ChildPath '.github'
    if (Test-Path -LiteralPath $ghSrc) {
        $ghFiles = Get-ChildItem -LiteralPath $ghSrc -Recurse -File
        foreach ($gf in $ghFiles) {
            $rel = [System.IO.Path]::GetRelativePath($ghSrc, $gf.FullName)
            $dst = Join-Path -Path (Join-Path -Path $Project -ChildPath '.github') -ChildPath $rel
            if ($PSCmdlet.ShouldProcess($dst, 'install .github customization')) {
                $status = Copy-WithBackup -Source $gf.FullName -Destination $dst -Stamp $stamp -ForceOverwrite:$Force
                if ($status -eq 'preserved') {
                    Write-InstallWarning -Text ".github/$rel already exists - left untouched (.agent-kit written)"
                }
            }
        }
    }

    $agentsMdSrc = Join-Path -Path $KitRoot -ChildPath 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsMdSrc) {
        $status = Copy-WithBackup -Source $agentsMdSrc -Destination (Join-Path -Path $Project -ChildPath 'AGENTS.md') -Stamp $stamp -ForceOverwrite:$Force
        Write-InstallDetail -Text "AGENTS.md: $status"
    }

    # ------------------------------------------------------------ 3. .vscode ---
    Write-InstallStep -Text 'Installing VS Code settings, tasks, launch, MCP & extensions'
    $vscodeDir = Join-Path -Path $Project -ChildPath '.vscode'
    New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null

    foreach ($file in @('settings.json', 'tasks.json', 'launch.json', 'extensions.json', 'mcp.json', 'PSScriptAnalyzerSettings.psd1', 'keybindings.recommended.json')) {
        $src = Join-Path -Path $KitRoot -ChildPath ".vscode/$file"
        $dst = Join-Path -Path $vscodeDir -ChildPath $file
        if (-not (Test-Path -LiteralPath $src)) { continue }

        $override = $null
        if ($file -in @('tasks.json', 'launch.json', 'mcp.json')) {
            $raw = [System.IO.File]::ReadAllText($src)
            $raw = $raw.Replace('${workspaceFolder}/Agent.ps1', '${workspaceFolder}/.agent/Agent.ps1')
            $raw = $raw.Replace('''${workspaceFolder}/Agent.ps1''', '''${workspaceFolder}/.agent/Agent.ps1''')
            $raw = $raw.Replace('${workspaceFolder}/agent-doctor.ps1', '${workspaceFolder}/.agent/agent-doctor.ps1')
            $raw = $raw.Replace('${workspaceFolder}/tools/', '${workspaceFolder}/.agent/tools/')
            $override = $raw
        }

        if ($PSCmdlet.ShouldProcess($dst, "install .vscode/$file")) {
            $status = Copy-WithBackup -Source $src -Destination $dst -Stamp $stamp -ContentOverride $override -ForceOverwrite:$Force
            if ($status -eq 'preserved') {
                Write-InstallWarning -Text ".vscode/$file already exists - left untouched ($file.agent-kit written)"
            }
            else {
                Write-InstallDetail -Text "$file $status"
            }
        }
    }

    # .editorconfig at project root
    $ecSrc = Join-Path -Path $KitRoot -ChildPath '.editorconfig'
    if (Test-Path -LiteralPath $ecSrc) {
        $ecDst = Join-Path -Path $Project -ChildPath '.editorconfig'
        $status = Copy-WithBackup -Source $ecSrc -Destination $ecDst -Stamp $stamp -ForceOverwrite:$Force
        Write-InstallDetail -Text ".editorconfig $status"
    }
}

# ------------------------------------------------------------- 4. gitignore ----
Write-InstallStep -Text 'Protecting secrets and session logs from git'
$gitignore = Join-Path -Path $Project -ChildPath '.gitignore'
$needed = @(
    '# agent: sessions and audit logs contain prompts and full tool output',
    '.agent/sessions/',
    '.agent/logs/',
    '.agent/todo.md',
    '.github/hooks/tool-use.log',
    '# agent: never commit keys or protected credential stores',
    '.agent/secrets.xml',
    '*.apikey',
    '.env',
    '# dotnet / ps build output',
    'bin/', 'obj/', 'artifacts/', 'TestResults/',
    '*.user', '*.suo', '.vs/'
)
$existing = if (Test-Path -LiteralPath $gitignore) { Get-Content -LiteralPath $gitignore } else { @() }
$toAdd = @($needed | Where-Object { $existing -notcontains $_ })
if ($toAdd.Count -gt 0) {
    if ($toAdd[0] -ne $needed[0]) { $toAdd = @('', '# --- added by the PS/.NET agent installer ---') + $toAdd }
    Add-Content -LiteralPath $gitignore -Value $toAdd
    Write-InstallDetail -Text "$($toAdd.Count) entries added to .gitignore"
}
else {
    Write-InstallDetail -Text '.gitignore already covers the agent'
}

# ----------------------------------------------------------------- 5. key ----
Write-InstallStep -Text 'BYOK API key (for standalone Agent.ps1)'
$cfgPath = if ($Project -eq $KitRoot) {
    Join-Path -Path $KitRoot -ChildPath 'config/agent.config.json'
}
else {
    Join-Path -Path $Project -ChildPath '.agent/config/agent.config.json'
}
$cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
$envName = $cfg.provider.apiKeyEnv
$already = [Environment]::GetEnvironmentVariable($envName)

if ($StoreKey -eq 'skip' -and -not $ApiKey) {
    Write-InstallDetail -Text "skipped (VS Code Copilot uses GitHub Copilot sign-in; for standalone Agent.ps1 set `$env:$envName or re-run with -StoreKey persist)."
}
elseif ($already -and -not $ApiKey) {
    Write-InstallDetail -Text "`$env:$envName is already set (length $($already.Length))"
}
else {
    if (-not $ApiKey) {
        Write-Host -Object '    paste your API key (input hidden), or press Enter to skip: ' -NoNewline
        $secure = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    if ($ApiKey) {
        if ($StoreKey -eq 'session') {
            Set-Item -Path "env:$envName" -Value $ApiKey
            Write-InstallDetail -Text 'set for this PowerShell session only'
        }
        else {
            $storeDir = Join-Path -Path $HOME -ChildPath '.agent'
            New-Item -ItemType Directory -Force -Path $storeDir | Out-Null
            $storeFile = Join-Path -Path $storeDir -ChildPath 'secrets.xml'

            $entries = [System.Collections.Generic.List[object]]::new()
            if (Test-Path -LiteralPath $storeFile) {
                try {
                    foreach ($existingEntry in @(Import-Clixml -LiteralPath $storeFile)) {
                        if ($existingEntry -and $existingEntry.UserName -ne $envName) { $entries.Add($existingEntry) }
                    }
                }
                catch {
                    Write-InstallWarning -Text "existing store unreadable, starting a new one: $($_.Exception.Message)"
                }
            }

            $entries.Add([pscustomobject]@{
                    UserName = $envName
                    Password = ConvertTo-ProtectedSecret -PlainText $ApiKey
                })

            if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                Write-InstallWarning -Text 'not on Windows: store is protected by file permissions only (chmod 600).'
            }
            $entries | Export-Clixml -LiteralPath $storeFile -Force
            if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                try { & chmod 600 $storeFile } catch { Write-InstallWarning -Text "could not chmod 600: $($_.Exception.Message)" }
            }
            Write-InstallDetail -Text "stored in $storeFile (DPAPI on Windows). Agent.ps1 loads it automatically."
        }
    }
    else {
        Write-InstallWarning -Text 'no key provided'
    }
}

# --------------------------------------------------------------- 6. doctor ----
Write-InstallStep -Text 'Verifying the installation'
$doctor = if ($Project -eq $KitRoot) {
    Join-Path -Path $KitRoot -ChildPath 'agent-doctor.ps1'
}
else {
    Join-Path -Path $Project -ChildPath '.agent/agent-doctor.ps1'
}
$pwsh = (Get-Command -Name pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) {
    $fbPwsh = Join-Path -Path $HOME -ChildPath '.local/pwsh/pwsh'
    if (Test-Path -LiteralPath $fbPwsh) { $pwsh = $fbPwsh }
}
if (-not $pwsh) { $pwsh = (Get-Command -Name powershell -ErrorAction SilentlyContinue).Source }

if ($pwsh) {
    & $pwsh -NoLogo -NoProfile -File $doctor -Workspace $Project
    $code = $LASTEXITCODE
}
else {
    Write-InstallWarning -Text 'neither pwsh nor powershell found on PATH - cannot run the doctor'
    $code = 1
}

# --------------------------------------------------------------- 7. next ------
Write-Host -Object ''
Write-Host -Object ('=' * 60) -ForegroundColor DarkCyan
if ($code -eq 0) { Write-Host -Object '  INSTALLED AND VERIFIED' -ForegroundColor Green }
else { Write-Host -Object '  INSTALLED - some checks need attention (see above)' -ForegroundColor Yellow }
Write-Host -Object ''
Write-Host -Object '  Next steps:' -ForegroundColor White
Write-Host -Object '    1. Open folder in VS Code: code ' -NoNewline; Write-Host -Object $Project
Write-Host -Object '    2. Install recommended extensions when VS Code prompts (including GitHub Copilot + PowerShell + C# Dev Kit)'
Write-Host -Object '    3. In Copilot Chat, pick agent "PS-DotNet-Architect" (Manual permissions active by default)'
Write-Host -Object '    4. Optional terminal loop: Ctrl+Shift+P > Tasks: Run Task > "Agent: run task (approve every step)"'
Write-Host -Object '    5. Optional shortcuts: merge .vscode/keybindings.recommended.json into your User keybindings.json'
Write-Host -Object ''
exit $code
