<#
.SYNOPSIS
    Minimal, zero-dependency stdio MCP (Model Context Protocol) server for VS Code Copilot.
.DESCRIPTION
    Exposes safe, workspace-bounded PowerShell and .NET tools over JSON-RPC 2.0 on stdin/stdout.
    VS Code prompts the user for manual confirmation when manual permissions are active.
#>
[CmdletBinding()]
param(
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:McpRoot = Split-Path -Parent $PSScriptRoot
$script:Workspace = (Resolve-Path -LiteralPath $Workspace).Path

# Reuse the agent's config, path-guard, deny-pattern, and tool implementations.
. (Join-Path -Path $script:McpRoot -ChildPath 'AgentConfig.ps1')
. (Join-Path -Path $script:McpRoot -ChildPath 'AgentTools.ps1')
. (Join-Path -Path $script:McpRoot -ChildPath 'AgentApproval.ps1')

$cfgPath = Join-Path -Path $script:McpRoot -ChildPath 'config/agent.config.json'
$script:Cfg = Read-AgentConfig -Path $cfgPath
$script:CommandTimeout = [int]$script:Cfg.agent.commandTimeoutSec
$script:Registry = New-AgentToolRegistry

function Write-McpResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Payload)

    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Get-McpToolDefinition {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        @{
            name        = 'ps_analyze'
            description = 'Run PSScriptAnalyzer (with PowerShell 5.1 + 7 compatibility checks) on a file or directory.'
            inputSchema = $script:Registry['RunPwshAnalysis'].Parameters
            annotations = @{ readOnlyHint = $true; destructiveHint = $false }
        },
        @{
            name        = 'ps_pester'
            description = 'Run Pester v5+ tests on a path inside the workspace.'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    path     = @{ type = 'string'; description = 'Test file or folder.' }
                    filter   = @{ type = 'string'; description = 'Optional test filter.' }
                    coverage = @{ type = 'boolean'; description = 'Collect coverage.' }
                }
            }
            annotations = @{ readOnlyHint = $false; destructiveHint = $false }
        },
        @{
            name        = 'ps_inspect'
            description = 'Inspect PowerShell cmdlet syntax, module exports, or .NET types in the local host.'
            inputSchema = $script:Registry['InspectPowerShell'].Parameters
            annotations = @{ readOnlyHint = $true; destructiveHint = $false }
        },
        @{
            name        = 'ps_test_manifest'
            description = 'Validate a PowerShell .psd1 module manifest and verify clean Import-Module behavior.'
            inputSchema = $script:Registry['TestPsManifest'].Parameters
            annotations = @{ readOnlyHint = $true; destructiveHint = $false }
        },
        @{
            name        = 'ps_new_module'
            description = 'Scaffold an enterprise PowerShell script or binary C# cmdlet module inside the workspace.'
            inputSchema = $script:Registry['NewPsModule'].Parameters
            annotations = @{ readOnlyHint = $false; destructiveHint = $false }
        },
        @{
            name        = 'dotnet_build'
            description = 'Build a .NET project or solution and return compiler diagnostics verbatim.'
            inputSchema = $script:Registry['RunBuild'].Parameters
            annotations = @{ readOnlyHint = $false; destructiveHint = $false }
        },
        @{
            name        = 'dotnet_test'
            description = 'Run dotnet test on a solution or test project.'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    path     = @{ type = 'string'; description = 'Project or solution path.' }
                    filter   = @{ type = 'string'; description = 'Test filter expression.' }
                    coverage = @{ type = 'boolean'; description = 'Collect XPlat code coverage.' }
                }
            }
            annotations = @{ readOnlyHint = $false; destructiveHint = $false }
        },
        @{
            name        = 'dotnet_pack'
            description = 'Pack a .NET project into NuGet artifacts locally (does not push).'
            inputSchema = $script:Registry['DotnetPackPublish'].Parameters
            annotations = @{ readOnlyHint = $false; destructiveHint = $false }
        },
        @{
            name        = 'dotnet_solution'
            description = 'Manage .NET solutions, project references, formatting checks, and package vulnerability audits.'
            inputSchema = $script:Registry['DotnetSolution'].Parameters
            annotations = @{ readOnlyHint = $false; destructiveHint = $false }
        },
        @{
            name        = 'verify_signature'
            description = 'Inspect Authenticode or NuGet package signatures without modifying files.'
            inputSchema = @{
                type       = 'object'
                required   = @('action', 'path')
                properties = @{
                    action = @{ type = 'string'; enum = @('verify-ps', 'verify-nuget') }
                    path   = @{ type = 'string' }
                }
            }
            annotations = @{ readOnlyHint = $true; destructiveHint = $false }
        }
    )
}

function Invoke-McpToolCall {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{}
    )

    $flat = ($Arguments.Values | ForEach-Object { [string]$_ }) -join ' '
    $hit = Test-DenyPattern -Text ($Name + ' ' + $flat)
    if ($hit) {
        return [pscustomobject]@{ ok = $false; output = "BLOCKED by deny pattern: $hit" }
    }

    switch ($Name) {
        'ps_analyze' { return (& $script:Registry['RunPwshAnalysis'].Script -ToolArgs $Arguments) }
        'ps_pester' { $Arguments['kind'] = 'pester'; return (& $script:Registry['RunTests'].Script -ToolArgs $Arguments) }
        'ps_inspect' { return (& $script:Registry['InspectPowerShell'].Script -ToolArgs $Arguments) }
        'ps_test_manifest' { return (& $script:Registry['TestPsManifest'].Script -ToolArgs $Arguments) }
        'ps_new_module' { return (& $script:Registry['NewPsModule'].Script -ToolArgs $Arguments) }
        'dotnet_build' { return (& $script:Registry['RunBuild'].Script -ToolArgs $Arguments) }
        'dotnet_test' { $Arguments['kind'] = 'dotnet'; return (& $script:Registry['RunTests'].Script -ToolArgs $Arguments) }
        'dotnet_pack' { return (& $script:Registry['DotnetPackPublish'].Script -ToolArgs $Arguments) }
        'dotnet_solution' { return (& $script:Registry['DotnetSolution'].Script -ToolArgs $Arguments) }
        'verify_signature' { return (& $script:Registry['CodeSign'].Script -ToolArgs $Arguments) }
        default { return [pscustomobject]@{ ok = $false; output = "Unknown MCP tool: $Name" } }
    }
}

# ----------------------------------------------------------------- stdio loop --
while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $req = $null
    try {
        $req = $line | ConvertFrom-Json -AsHashtable -Depth 20
    }
    catch {
        Write-McpResponse -Payload @{
            jsonrpc = '2.0'
            id      = $null
            error   = @{ code = -32700; message = "Parse error: $($_.Exception.Message)" }
        }
        continue
    }

    $id = if ($req.ContainsKey('id')) { $req['id'] } else { $null }
    $method = [string]$req['method']
    $params = if ($req.ContainsKey('params') -and $req['params']) { $req['params'] } else { @{} }

    if ($method -eq 'notifications/initialized' -or $method -eq 'notifications/cancelled') {
        continue
    }

    try {
        switch ($method) {
            'initialize' {
                $proto = if ($params.ContainsKey('protocolVersion')) { [string]$params['protocolVersion'] } else { '2024-11-05' }
                Write-McpResponse -Payload @{
                    jsonrpc = '2.0'
                    id      = $id
                    result  = @{
                        protocolVersion = $proto
                        capabilities    = @{ tools = @{ listChanged = $false } }
                        serverInfo      = @{ name = 'ps-dotnet-tools'; version = '1.0.0' }
                    }
                }
            }
            'ping' {
                Write-McpResponse -Payload @{ jsonrpc = '2.0'; id = $id; result = @{} }
            }
            'tools/list' {
                Write-McpResponse -Payload @{
                    jsonrpc = '2.0'
                    id      = $id
                    result  = @{ tools = (Get-McpToolDefinition) }
                }
            }
            'tools/call' {
                $toolName = [string]$params['name']
                $toolArgs = if ($params.ContainsKey('arguments') -and $params['arguments']) { $params['arguments'] } else { @{} }
                $res = Invoke-McpToolCall -Name $toolName -Arguments $toolArgs
                Write-McpResponse -Payload @{
                    jsonrpc = '2.0'
                    id      = $id
                    result  = @{
                        content = @(@{ type = 'text'; text = [string]$res.output })
                        isError = (-not [bool]$res.ok)
                    }
                }
            }
            default {
                if ($null -ne $id) {
                    Write-McpResponse -Payload @{
                        jsonrpc = '2.0'
                        id      = $id
                        error   = @{ code = -32601; message = "Method not found: $method" }
                    }
                }
            }
        }
    }
    catch {
        if ($null -ne $id) {
            Write-McpResponse -Payload @{
                jsonrpc = '2.0'
                id      = $id
                error   = @{ code = -32603; message = $_.Exception.Message }
            }
        }
    }
}
