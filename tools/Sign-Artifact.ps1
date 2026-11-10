<#
.SYNOPSIS
    Verifies or applies Authenticode signatures on PowerShell files without storing secrets.
.PARAMETER Path
    Target script, module, or manifest file.
.PARAMETER VerifyOnly
    Inspect existing signature status instead of signing.
.PARAMETER Thumbprint
    Code-signing certificate thumbprint from Cert:\CurrentUser\My or Cert:\LocalMachine\My.
.PARAMETER TimestampServer
    RFC 3161 timestamp server URL.
.EXAMPLE
    pwsh -File tools/Sign-Artifact.ps1 -Path ./src/MyModule/MyModule.psm1 -VerifyOnly
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [switch]$VerifyOnly,

    [string]$Thumbprint,

    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

$resolved = (Resolve-Path -LiteralPath $Path).Path

if ($VerifyOnly) {
    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        return [pscustomobject]@{
            Path   = $resolved
            Status = 'NotSupportedOnNonWindows'
            Note   = 'Authenticode Get-AuthenticodeSignature requires Windows. Use dotnet nuget verify for NuGet packages cross-platform.'
        }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $resolved
    return [pscustomobject]@{
        Path       = $resolved
        Status     = [string]$sig.Status
        Subject    = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null })
        Thumbprint = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null })
    }
}

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    throw 'PowerShell Authenticode signing (Set-AuthenticodeSignature) is supported on Windows hosts only.'
}
if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
    throw 'Certificate -Thumbprint is required when signing.'
}

$cert = Get-ChildItem -Path 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My' -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $Thumbprint } |
    Select-Object -First 1

if (-not $cert) {
    throw "Code-signing certificate with thumbprint '$Thumbprint' was not found in CurrentUser\\My or LocalMachine\\My."
}

if ($PSCmdlet.ShouldProcess($resolved, "Apply Authenticode signature with cert $Thumbprint")) {
    $res = Set-AuthenticodeSignature -LiteralPath $resolved -Certificate $cert -TimestampServer $TimestampServer -HashAlgorithm 'SHA256'
    return [pscustomobject]@{
        Path   = $resolved
        Status = [string]$res.Status
        Note   = $res.StatusMessage
    }
}
