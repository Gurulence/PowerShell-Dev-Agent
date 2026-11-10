<#
.SYNOPSIS
    Runs Pester v5+ on a test file or directory for VS Code launch/task integration.
.PARAMETER Path
    Path to a .Tests.ps1 file or tests folder.
.PARAMETER OutputVerbosity
    Pester output verbosity: Detailed | Normal | Minimal.
.EXAMPLE
    pwsh -File tools/Invoke-AgentPester.ps1 -Path ./tests/AgentTools.Tests.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [ValidateSet('Detailed', 'Normal', 'Minimal', 'Diagnostic')]
    [string]$OutputVerbosity = 'Detailed'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Test path not found: $Path"
}

Import-Module -Name Pester -MinimumVersion 5.0 -ErrorAction Stop

$cfg = New-PesterConfiguration
$cfg.Run.Path = @((Resolve-Path -LiteralPath $Path).Path)
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = $OutputVerbosity

$result = Invoke-Pester -Configuration $cfg
if ($result.FailedCount -gt 0) {
    exit 1
}
exit 0
