<#
.SYNOPSIS
    Scaffolds an enterprise .NET class library solution with xUnit tests and strict analyzer defaults.
.PARAMETER Name
    Solution and library name (e.g. Contoso.Core).
.PARAMETER OutputPath
    Root folder where the solution will be created.
.PARAMETER TargetFramework
    Target framework moniker (default net8.0).
.EXAMPLE
    pwsh -File tools/New-EnterpriseDotnetSolution.ps1 -Name Contoso.Core -OutputPath ./my-lib
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]*$')]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$TargetFramework = 'net8.0'
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($OutputPath)

if (-not $PSCmdlet.ShouldProcess($root, "Create .NET solution '$Name'")) {
    return
}

$srcDir = Join-Path -Path $root -ChildPath "src/$Name"
$testDir = Join-Path -Path $root -ChildPath "tests/$Name.Tests"
New-Item -ItemType Directory -Force -Path $srcDir, $testDir | Out-Null

$propsContent = @"
<Project>
  <PropertyGroup>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <EnableNETAnalyzers>true</EnableNETAnalyzers>
    <AnalysisLevel>latest</AnalysisLevel>
    <Deterministic>true</Deterministic>
    <GenerateDocumentationFile Condition="!`$(MSBuildProjectName.EndsWith('.Tests')) And !`$(MSBuildProjectName.EndsWith('.Test')) And '`$(IsTestProject)' != 'true'">true</GenerateDocumentationFile>
  </PropertyGroup>
</Project>
"@
[System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'Directory.Build.props'), $propsContent, [System.Text.UTF8Encoding]::new($false))

$dotnet = (Get-Command -Name dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet) {
    $fb = Join-Path -Path $HOME -ChildPath '.local/dotnet/dotnet'
    if (Test-Path -LiteralPath $fb) { $dotnet = $fb } else { throw 'dotnet SDK not found on PATH.' }
}

& $dotnet new sln -n $Name -o $root --force | Out-Null
& $dotnet new classlib -n $Name -o $srcDir -f $TargetFramework --force | Out-Null
& $dotnet new xunit -n "$Name.Tests" -o $testDir -f $TargetFramework --force | Out-Null
& $dotnet sln (Join-Path -Path $root -ChildPath "$Name.sln") add (Join-Path -Path $srcDir -ChildPath "$Name.csproj") (Join-Path -Path $testDir -ChildPath "$Name.Tests.csproj") | Out-Null
& $dotnet add (Join-Path -Path $testDir -ChildPath "$Name.Tests.csproj") reference (Join-Path -Path $srcDir -ChildPath "$Name.csproj") | Out-Null

$libCode = @"
namespace $Name;

/// <summary>
/// Sample service contract demonstrating XML documentation and async cancellation conventions.
/// </summary>
public interface IGreetingService
{
    /// <summary>
    /// Formats a greeting asynchronously.
    /// </summary>
    Task<string> FormatAsync(string name, CancellationToken cancellationToken = default);
}

/// <summary>
/// Default implementation of <see cref="IGreetingService"/>.
/// </summary>
public sealed class GreetingService : IGreetingService
{
    /// <inheritdoc />
    public Task<string> FormatAsync(string name, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(`$"Hello, {name}");
    }
}
"@
Remove-Item -LiteralPath (Join-Path -Path $srcDir -ChildPath 'Class1.cs') -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText((Join-Path -Path $srcDir -ChildPath 'GreetingService.cs'), $libCode, [System.Text.UTF8Encoding]::new($false))

$testCode = @"
using $Name;

namespace $Name.Tests;

public sealed class GreetingServiceTests
{
    [Fact]
    public async Task FormatAsync_ReturnsExpectedGreeting()
    {
        var sut = new GreetingService();
        var result = await sut.FormatAsync("Arena");
        Assert.Equal("Hello, Arena", result);
    }
}
"@
Remove-Item -LiteralPath (Join-Path -Path $testDir -ChildPath 'UnitTest1.cs') -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText((Join-Path -Path $testDir -ChildPath 'GreetingServiceTests.cs'), $testCode, [System.Text.UTF8Encoding]::new($false))

Write-Output "Scaffolded enterprise .NET solution '$Name' at: $root"
