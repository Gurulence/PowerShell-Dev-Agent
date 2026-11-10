<#
.SYNOPSIS
    Diagnoses everything the PS/.NET agent (both VS Code Copilot & standalone Agent.ps1) depends on.
.DESCRIPTION
    Checks PowerShell 7, Windows PowerShell 5.1, the .NET SDK, git, Pester, PSScriptAnalyzer,
    agent configuration, Copilot custom agent files, MCP server config, strict approval settings,
    and recommended VS Code extensions.
    Exit code 0 = ready, 1 = blocking issue found.
.PARAMETER Workspace
    The project folder to inspect. Defaults to the current directory.
.PARAMETER VerifyModule
    Optional path to a .psd1 manifest to test importing.
.EXAMPLE
    pwsh -File agent-doctor.ps1
.EXAMPLE
    pwsh -File .agent/agent-doctor.ps1 -Workspace C:\src\MyLib
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive diagnostic terminal report')]
param(
    [string]$Workspace,
    [string]$VerifyModule
)

$ErrorActionPreference = 'Continue'
$script:Fail = 0
$script:Warn = 0

function Write-DoctorSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)

    Write-Host -Object ''
    Write-Host -Object "== $Title " -ForegroundColor Cyan -NoNewline
    Write-Host -Object ('=' * [Math]::Max(0, 60 - $Title.Length)) -ForegroundColor DarkCyan
}

function Invoke-DoctorCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Test,
        [string]$Fix,
        [switch]$Optional
    )

    Write-Host -Object ('  {0,-44}' -f $Name) -NoNewline
    try {
        $detail = & $Test
        if ($detail -eq $false) { throw 'failed' }
        Write-Host -Object ' OK' -ForegroundColor Green -NoNewline
        if ($detail -is [string] -and $detail -ne 'true') {
            Write-Host -Object "  $detail" -ForegroundColor DarkGray
        }
        else {
            Write-Host -Object ''
        }
    }
    catch {
        if ($Optional) {
            Write-Host -Object ' MISSING (optional)' -ForegroundColor Yellow
            $script:Warn++
        }
        else {
            Write-Host -Object ' FAIL' -ForegroundColor Red
            $script:Fail++
        }
        if ($Fix) { Write-Host -Object "      fix: $Fix" -ForegroundColor Yellow }
        if ($_.Exception.Message -and $_.Exception.Message -ne 'failed') {
            Write-Host -Object "      detail: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Workspace) { $Workspace = (Get-Location).Path }
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path

Write-Host -Object ''
Write-Host -Object 'PS/.NET AGENT - ENVIRONMENT DOCTOR' -ForegroundColor White
Write-Host -Object "workspace: $Workspace" -ForegroundColor DarkGray
Write-Host -Object "agent    : $root" -ForegroundColor DarkGray

# --------------------------------------------------------------- runtimes ----
Write-DoctorSection -Title 'Runtimes'

$script:pwshExe = $null
Invoke-DoctorCheck -Name 'PowerShell 7 (pwsh)' -Test {
    $c = Get-Command -Name pwsh -ErrorAction SilentlyContinue
    if (-not $c) {
        $candidates = @(
            (Join-Path -Path $HOME -ChildPath '.local/pwsh/pwsh'),
            '/usr/bin/pwsh', '/usr/local/bin/pwsh', '/opt/microsoft/powershell/7/pwsh',
            'C:\Program Files\PowerShell\7\pwsh.exe'
        )
        foreach ($cand in $candidates) {
            if (Test-Path -LiteralPath $cand) { $c = [pscustomobject]@{ Source = $cand }; break }
        }
    }
    if (-not $c) { throw 'pwsh not found on PATH' }
    $script:pwshExe = $c.Source
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        "v$($PSVersionTable.PSVersion) ($($c.Source))"
    }
    else {
        $v = & $c.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        "v$v ($($c.Source))"
    }
} -Fix 'winget install Microsoft.PowerShell | brew install --cask powershell | apt install powershell'

if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    Invoke-DoctorCheck -Name 'Windows PowerShell 5.1' -Test {
        $c = Get-Command -Name powershell.exe -ErrorAction SilentlyContinue
        if (-not $c) { throw 'powershell.exe not found' }
        $v = & $c.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        "v$v"
    } -Fix 'Enable Windows PowerShell 5.1 (WMF 5.1 / built into Windows 10/11)'
}
else {
    Write-Host -Object ('  {0,-44}' -f 'Windows PowerShell 5.1') -NoNewline
    Write-Host -Object ' N/A (not Windows)' -ForegroundColor DarkGray
    Write-Host -Object '      5.1 compatibility is checked statically via PSScriptAnalyzer PSUseCompatibleSyntax.' -ForegroundColor DarkGray
}

Invoke-DoctorCheck -Name '.NET SDK' -Test {
    $c = Get-Command -Name dotnet -ErrorAction SilentlyContinue
    if (-not $c) {
        $fb = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'C:\Program Files\dotnet\dotnet.exe' } else { Join-Path -Path $HOME -ChildPath '.local/dotnet/dotnet' }
        if (Test-Path -LiteralPath $fb) { $c = [pscustomobject]@{ Source = $fb } } else { throw 'dotnet not found' }
    }
    $v = & $c.Source --version
    $sdks = (& $c.Source --list-sdks) -join '; '
    "v$v  [$sdks]"
} -Fix 'https://dot.net/download or: winget install Microsoft.DotNet.SDK.8'

Invoke-DoctorCheck -Name 'git' -Test {
    $c = Get-Command -Name git -ErrorAction SilentlyContinue
    if (-not $c) { throw 'git not found' }
    (git --version)
} -Fix 'https://git-scm.com/downloads'

# ------------------------------------------------------------ PS modules ----
Write-DoctorSection -Title 'PowerShell modules'

Invoke-DoctorCheck -Name 'PSScriptAnalyzer' -Test {
    $m = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object -Property Version | Select-Object -Last 1
    if (-not $m) { throw 'not installed' }
    "v$($m.Version)"
} -Fix 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'

Invoke-DoctorCheck -Name 'Pester (>= 5.0)' -Test {
    $m = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Sort-Object -Property Version | Select-Object -Last 1
    if (-not $m) { throw 'Pester 5+ not installed' }
    "v$($m.Version)"
} -Fix 'Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser -Force'

Invoke-DoctorCheck -Name 'PSReadLine' -Optional -Test {
    $m = Get-Module -ListAvailable -Name PSReadLine | Sort-Object -Property Version | Select-Object -Last 1
    if (-not $m) { throw 'not installed' }
    "v$($m.Version)"
} -Fix 'Install-Module PSReadLine -Scope CurrentUser -Force'

Invoke-DoctorCheck -Name 'platyPS (help generation)' -Optional -Test {
    $m = Get-Module -ListAvailable -Name platyPS | Sort-Object -Property Version | Select-Object -Last 1
    if (-not $m) { throw 'not installed' }
    "v$($m.Version)"
} -Fix 'Install-Module platyPS -Scope CurrentUser -Force'

Invoke-DoctorCheck -Name 'PSScriptAnalyzer 5.1 syntax check' -Test {
    $probe = Invoke-ScriptAnalyzer -ScriptDefinition '$x = $true ? 1 : 2' `
        -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } } -ErrorAction Stop
    if (-not $probe) { throw 'the compatibility rule did not flag a ternary operator' }
    'detects 7-only syntax'
}

# ---------------------------------------------------------------- config ----
Write-DoctorSection -Title 'Standalone Agent & Configuration'

$cfgPath = Join-Path -Path $root -ChildPath 'config/agent.config.json'
Invoke-DoctorCheck -Name 'config/agent.config.json exists' -Test {
    if (-not (Test-Path -LiteralPath $cfgPath)) { throw "missing $cfgPath" }
    'found'
} -Fix 'restore config/agent.config.json from the kit'

$script:cfg = $null
Invoke-DoctorCheck -Name 'config parses & strict gate set' -Test {
    $script:cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    "model=$($script:cfg.provider.model) gate=$($script:cfg.agent.approvalGate)"
}

$envName = if ($script:cfg) { $script:cfg.provider.apiKeyEnv } else { 'OPENAI_API_KEY' }
Invoke-DoctorCheck -Name "BYOK API key ($envName)" -Optional -Test {
    . (Join-Path -Path $root -ChildPath 'AgentConfig.ps1')
    $v = Get-AgentSecret -EnvName $envName
    if (-not $v) { throw "not found in `$env:$envName nor ~/.agent/secrets.xml (only required for Agent.ps1; VS Code Copilot uses your GitHub Copilot sign-in)" }
    $from = if ([Environment]::GetEnvironmentVariable($envName)) { 'environment' } else { 'store (~/.agent/secrets.xml)' }
    "length=$($v.Length) from=$from"
} -Fix "./Install-Agent.ps1 -Project $Workspace   (or set `$env:$envName)"

Invoke-DoctorCheck -Name 'agent files, modes & tools present' -Test {
    $need = @(
        'Agent.ps1', 'AgentTools.ps1', 'AgentApproval.ps1', 'AgentLlm.ps1', 'AgentConfig.ps1',
        'prompts/modes/planner.md', 'prompts/modes/hybrid.md', 'prompts/modes/executor.md',
        'tools/PsDotnetMcpServer.ps1', 'tools/Invoke-AgentPester.ps1'
    )
    $missing = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath $_)) })
    if ($missing.Count -gt 0) { throw "missing: $($missing -join ', ')" }
    'all present'
}

Invoke-DoctorCheck -Name 'Agent.ps1 starts in dry-run' -Test {
    if (-not $script:pwshExe) { throw 'pwsh unavailable' }
    $out = & $script:pwshExe -NoLogo -NoProfile -File (Join-Path -Path $root -ChildPath 'Agent.ps1') -DryRun -NoColor -Workspace $Workspace 'doctor smoke test' 2>&1
    $joined = ($out | Out-String)
    if ($joined -notmatch 'model not called') { throw "unexpected output: $($joined.Substring(0, [Math]::Min(200, $joined.Length)))" }
    'loop, config, prompt assembly OK'
}

# ------------------------------------------------------------- copilot/vscode --
Write-DoctorSection -Title 'VS Code Copilot Agent & Workspace'

Invoke-DoctorCheck -Name '.github/agents/*.agent.md present' -Test {
    $dir = Join-Path -Path $Workspace -ChildPath '.github/agents'
    if (-not (Test-Path -LiteralPath $dir)) { throw 'missing .github/agents' }
    $agents = @(Get-ChildItem -LiteralPath $dir -Filter '*.agent.md')
    if ($agents.Count -eq 0) { throw 'no *.agent.md files found' }
    "$($agents.Count) agent(s): $(($agents.Name) -join ', ')"
} -Fix 'Run Install-Agent.ps1 to install .github/agents'

Invoke-DoctorCheck -Name '.github/copilot-instructions.md present' -Test {
    $f = Join-Path -Path $Workspace -ChildPath '.github/copilot-instructions.md'
    if (-not (Test-Path -LiteralPath $f)) { throw 'missing' }
    'ok'
}

Invoke-DoctorCheck -Name '.github/hooks/safety-gate.json present' -Test {
    $f = Join-Path -Path $Workspace -ChildPath '.github/hooks/safety-gate.json'
    if (-not (Test-Path -LiteralPath $f)) { throw 'missing' }
    $null = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json
    'valid JSON'
}

Invoke-DoctorCheck -Name '.vscode/mcp.json valid' -Test {
    $f = Join-Path -Path $Workspace -ChildPath '.vscode/mcp.json'
    if (-not (Test-Path -LiteralPath $f)) { throw 'missing' }
    $m = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json
    if (-not $m.servers.'ps-dotnet-tools') { throw 'ps-dotnet-tools server missing' }
    'ps-dotnet-tools configured'
}

Invoke-DoctorCheck -Name '.vscode/settings.json strict approvals' -Test {
    $f = Join-Path -Path $Workspace -ChildPath '.vscode/settings.json'
    if (-not (Test-Path -LiteralPath $f)) { throw 'missing' }
    $raw = Get-Content -Raw -LiteralPath $f
    if ($raw -notmatch '"chat\.tools\.global\.autoApprove"\s*:\s*false') { throw 'chat.tools.global.autoApprove is not false' }
    if ($raw -notmatch '"chat\.tools\.terminal\.enableAutoApprove"\s*:\s*false') { throw 'chat.tools.terminal.enableAutoApprove is not false' }
    'manual approvals enforced'
}

Invoke-DoctorCheck -Name 'workspace is writable' -Test {
    $probe = Join-Path -Path $Workspace -ChildPath ('.agent/doctor-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.tmp')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $probe) | Out-Null
    Set-Content -LiteralPath $probe -Value 'ok'
    Remove-Item -LiteralPath $probe -Force
    'ok'
}

Invoke-DoctorCheck -Name 'git repository' -Optional -Test {
    Push-Location -LiteralPath $Workspace
    try {
        $r = git rev-parse --is-inside-work-tree 2>$null
        if ($r -ne 'true') { throw 'not a git repo' }
        $branch = git rev-parse --abbrev-ref HEAD
        "branch=$branch"
    }
    finally { Pop-Location }
} -Fix 'git init'

Invoke-DoctorCheck -Name '.editorconfig present' -Optional -Test {
    if (-not (Test-Path -LiteralPath (Join-Path -Path $Workspace -ChildPath '.editorconfig'))) { throw 'missing' }
    'ok'
}

if ($VerifyModule) {
    Write-DoctorSection -Title 'Module verification'
    Invoke-DoctorCheck -Name "import $VerifyModule" -Test {
        $file = (Resolve-Path -LiteralPath $VerifyModule).Path
        $m = Test-ModuleManifest -Path $file
        Import-Module -Name $file -Force -ErrorAction Stop
        $cmds = (Get-Command -Module $m.Name).Count
        "name=$($m.Name) v$($m.Version) exported=$cmds"
    } -Fix 'fix the manifest errors above'
}

# ------------------------------------------------------------ vscode ext ----
Write-DoctorSection -Title 'VS Code extensions'
$extFile = Join-Path -Path $Workspace -ChildPath '.vscode/extensions.json'
if (Test-Path -LiteralPath $extFile) {
    $code = Get-Command -Name code -ErrorAction SilentlyContinue
    if (-not $code) {
        Write-Host -Object '  code CLI not on PATH - skipping live extension check.' -ForegroundColor Yellow
        Write-Host -Object '  Install recommendations from .vscode/extensions.json inside VS Code.' -ForegroundColor DarkGray
        $script:Warn++
    }
    else {
        $installed = @(& $code --list-extensions 2>$null)
        $cleanJson = (Get-Content -LiteralPath $extFile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
        $rec = ($cleanJson | ConvertFrom-Json).recommendations
        $missing = @($rec | Where-Object { $installed -notcontains $_ })
        Invoke-DoctorCheck -Name "all $($rec.Count) recommended extensions installed" -Test {
            if ($missing.Count -gt 0) { throw "missing: $($missing -join ', ')" }
            'ok'
        } -Fix ('code --install-extension ' + ($missing -join ' --install-extension '))
    }
}
else {
    Write-Host -Object '  .vscode/extensions.json not found - skipped.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- result ----
Write-DoctorSection -Title 'Result'
if ($script:Fail -eq 0 -and $script:Warn -eq 0) {
    Write-Host -Object '  Everything checks out. You are ready.' -ForegroundColor Green
    exit 0
}
if ($script:Fail -eq 0) {
    Write-Host -Object "  Ready, with $($script:Warn) optional item(s) missing." -ForegroundColor Yellow
    exit 0
}
Write-Host -Object "  $($script:Fail) blocking issue(s), $($script:Warn) warning(s). Fix the items marked FAIL." -ForegroundColor Red
exit 1
