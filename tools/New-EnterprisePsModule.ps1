<#
.SYNOPSIS
    Scaffolds an enterprise PowerShell script module or binary C# cmdlet module.
.DESCRIPTION
    Creates a clean Public/Private/Tests structure, a validated .psd1 module manifest,
    PowerShell 5.1 + 7+ compatible loader .psm1 (for script modules) or C# PSCmdlet
    project (for binary modules), and an initial Pester test suite.
.PARAMETER Name
    Module name (e.g. Contoso.StorageTools).
.PARAMETER Kind
    script | binary
.PARAMETER OutputPath
    Destination folder for the module.
.PARAMETER Author
    Module author.
.PARAMETER Description
    Module description.
.PARAMETER TargetFramework
    Target framework for binary modules (default net8.0; use netstandard2.0 for PS 5.1 + 7+).
.EXAMPLE
    pwsh -File tools/New-EnterprisePsModule.ps1 -Name Contoso.Tools -Kind script -OutputPath ./src/Contoso.Tools
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]*$')]
    [string]$Name,

    [ValidateSet('script', 'binary')]
    [string]$Kind = 'script',

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$Author = 'Gurulence',
    [string]$Description = 'Enterprise PowerShell module',
    [string]$TargetFramework = 'net8.0'
)

$ErrorActionPreference = 'Stop'

$resolvedOut = [System.IO.Path]::GetFullPath($OutputPath)
$testsDir = Join-Path -Path $resolvedOut -ChildPath 'Tests'

if (-not $PSCmdlet.ShouldProcess($resolvedOut, "Scaffold $Kind PowerShell module '$Name'")) {
    return
}

New-Item -ItemType Directory -Force -Path $resolvedOut, $testsDir | Out-Null

$psd1Path = Join-Path -Path $resolvedOut -ChildPath "$Name.psd1"
$safeAuthor = $Author -replace '''', ''''''
$safeDesc = $Description -replace '''', ''''''

if ($Kind -eq 'script') {
    $pubDir = Join-Path -Path $resolvedOut -ChildPath 'Public'
    $privDir = Join-Path -Path $resolvedOut -ChildPath 'Private'
    New-Item -ItemType Directory -Force -Path $pubDir, $privDir | Out-Null

    $pubFunc = @'
function Get-SampleGreeting {
    <#
    .SYNOPSIS
        Returns a structured greeting object compatible with PowerShell 5.1 and 7+.
    .DESCRIPTION
        Demonstrates CmdletBinding, pipeline support, and typed PSCustomObject output.
    .PARAMETER Name
        Target name to greet.
    .EXAMPLE
        Get-SampleGreeting -Name 'World'
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    process {
        Write-Verbose -Message "Building greeting for '$Name'"
        [pscustomobject]@{
            PSTypeName = 'Sample.Greeting'
            Greeting   = "Hello, $Name"
            Timestamp  = [DateTimeOffset]::UtcNow
        }
    }
}
'@
    [System.IO.File]::WriteAllText((Join-Path -Path $pubDir -ChildPath 'Get-SampleGreeting.ps1'), $pubFunc.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    $privFunc = @'
function ConvertTo-SafeIdentifier {
    <#
    .SYNOPSIS
        Internal helper example.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}
'@
    [System.IO.File]::WriteAllText((Join-Path -Path $privDir -ChildPath 'ConvertTo-SafeIdentifier.ps1'), $privFunc.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    $psm1Content = @'
#Requires -Version 5.1
Set-StrictMode -Version Latest

$privateFiles = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private/*.ps1') -ErrorAction SilentlyContinue)
$publicFiles = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public/*.ps1') -ErrorAction SilentlyContinue)

foreach ($import in @($privateFiles + $publicFiles)) {
    try {
        . $import.FullName
    }
    catch {
        throw "Failed to import function '$($import.FullName)': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $publicFiles.BaseName
'@
    [System.IO.File]::WriteAllText((Join-Path -Path $resolvedOut -ChildPath "$Name.psm1"), $psm1Content.TrimStart(), [System.Text.UTF8Encoding]::new($false))

    New-ModuleManifest -Path $psd1Path `
        -RootModule "$Name.psm1" `
        -ModuleVersion '0.1.0' `
        -Author $safeAuthor `
        -CompanyName $safeAuthor `
        -Description $safeDesc `
        -PowerShellVersion '5.1' `
        -FunctionsToExport @('Get-SampleGreeting') `
        -CmdletsToExport @() `
        -VariablesToExport @() `
        -AliasesToExport @()

    $testContent = @"
BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent `$PSScriptRoot) -ChildPath '$Name.psd1') -Force
}

Describe '$Name' {
    It 'exports Get-SampleGreeting and emits structured output' {
        `$res = Get-SampleGreeting -Name 'Arena'
        `$res.Greeting | Should -Be 'Hello, Arena'
    }
}
"@
    [System.IO.File]::WriteAllText((Join-Path -Path $testsDir -ChildPath "$Name.Tests.ps1"), $testContent, [System.Text.UTF8Encoding]::new($false))
}
else {
    $pkgName = if ($TargetFramework -eq 'netstandard2.0') { 'PowerShellStandard.Library' } else { 'System.Management.Automation' }
    $pkgVer = if ($TargetFramework -eq 'netstandard2.0') { '5.1.1' } else { '7.4.6' }
    $psVerReq = if ($TargetFramework -eq 'netstandard2.0') { '5.1' } else { '7.4' }

    $csprojContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$TargetFramework</TargetFramework>
    <AssemblyName>$Name</AssemblyName>
    <RootNamespace>$Name</RootNamespace>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <CopyLocalLockFileAssemblies>true</CopyLocalLockFileAssemblies>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="$pkgName" Version="$pkgVer" PrivateAssets="all" />
  </ItemGroup>

  <ItemGroup>
    <None Include="$Name.psd1" CopyToOutputDirectory="PreserveNewest" />
  </ItemGroup>
</Project>
"@
    [System.IO.File]::WriteAllText((Join-Path -Path $resolvedOut -ChildPath "$Name.csproj"), $csprojContent, [System.Text.UTF8Encoding]::new($false))

    $csContent = @"
using System.Management.Automation;

namespace $Name;

/// <summary>
/// Sample greeting output record.
/// </summary>
public sealed record SampleGreetingResult(string Greeting, DateTimeOffset Timestamp);

/// <summary>
/// Emits a structured greeting object.
/// </summary>
[Cmdlet(VerbsCommon.Get, "SampleGreeting")]
[OutputType(typeof(SampleGreetingResult))]
public sealed class GetSampleGreetingCommand : PSCmdlet
{
    /// <summary>
    /// Target name to greet.
    /// </summary>
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true, ValueFromPipelineByPropertyName = true)]
    [ValidateNotNullOrEmpty]
    public string Name { get; set; } = string.Empty;

    /// <inheritdoc />
    protected override void ProcessRecord()
    {
        WriteVerbose(`$"Building greeting for '{Name}'");
        WriteObject(new SampleGreetingResult(`$"Hello, {Name}", DateTimeOffset.UtcNow));
    }
}
"@
    [System.IO.File]::WriteAllText((Join-Path -Path $resolvedOut -ChildPath 'GetSampleGreetingCommand.cs'), $csContent, [System.Text.UTF8Encoding]::new($false))

    New-ModuleManifest -Path $psd1Path `
        -RootModule "$Name.dll" `
        -ModuleVersion '0.1.0' `
        -Author $safeAuthor `
        -CompanyName $safeAuthor `
        -Description $safeDesc `
        -PowerShellVersion $psVerReq `
        -FunctionsToExport @() `
        -CmdletsToExport @('Get-SampleGreeting') `
        -VariablesToExport @() `
        -AliasesToExport @()

    $testContent = @"
BeforeAll {
    `$moduleDir = Split-Path -Parent `$PSScriptRoot
    `$dll = Get-ChildItem -Path (Join-Path -Path `$moduleDir -ChildPath 'bin') -Filter '$Name.dll' -Recurse | Select-Object -First 1
    if (-not `$dll) { throw 'Build the binary module first: dotnet build' }
    Import-Module -Name `$dll.FullName -Force
}

Describe '$Name (binary cmdlet)' {
    It 'exports Get-SampleGreeting' {
        `$res = Get-SampleGreeting -Name 'Arena'
        `$res.Greeting | Should -Be 'Hello, Arena'
    }
}
"@
    [System.IO.File]::WriteAllText((Join-Path -Path $testsDir -ChildPath "$Name.Tests.ps1"), $testContent, [System.Text.UTF8Encoding]::new($false))
}

if ($Kind -eq 'script') {
    $null = Test-ModuleManifest -Path $psd1Path -ErrorAction Stop
    Write-Output "Scaffolded script PowerShell module '$Name' at: $resolvedOut"
}
else {
    Write-Output "Scaffolded binary PowerShell module '$Name' at: $resolvedOut"
    Write-Output "Build first with: dotnet build `"$(Join-Path -Path $resolvedOut -ChildPath "$Name.csproj")`" -c Release"
}
