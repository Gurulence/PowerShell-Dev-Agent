<#
.SYNOPSIS
    Configuration loading, default merging, and secure credential retrieval for the PS/.NET agent.
#>

function Read-AgentConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $user = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json

    # Defaults first, user file overrides, so a partial config still works.
    $defaults = [pscustomobject]@{
        provider = [pscustomobject]@{
            name              = 'openai'
            baseUrl           = 'https://api.openai.com/v1'
            model             = 'gpt-4.1'
            apiKeyEnv         = 'OPENAI_API_KEY'
            apiKeyHeader      = 'Authorization'
            apiKeyPrefix      = 'Bearer '
            extraHeaders      = [pscustomobject]@{}
            temperature       = 0.2
            maxTokens         = 4096
            maxTokensParam    = 'max_tokens'
            requestTimeoutSec = 240
            maxRetries        = 3
        }
        agent    = [pscustomobject]@{
            mode                  = 'hybrid'
            maxTurns              = 40
            maxContextChars       = 120000
            approvalGate          = 'strict'
            allowOutsideWorkspace = $false
            auditLog              = $true
            commandTimeoutSec     = 300
            maxToolOutputChars    = 12000
            logDir                = '.agent/logs'
            sessionDir            = '.agent/sessions'
            todoFile              = '.agent/todo.md'
            pwshPath              = 'pwsh'
            windowsPowerShellPath = 'powershell'
            posixShell            = '/bin/bash'
            dotnetPath            = 'dotnet'
            gitPath               = 'git'
            denyPatterns          = @()
        }
    }

    $cfg = [pscustomobject]@{}
    foreach ($section in @('provider', 'agent')) {
        $merged = [ordered]@{}
        foreach ($prop in $defaults.$section.PSObject.Properties) {
            $merged[$prop.Name] = $prop.Value
        }
        if (($user.PSObject.Properties.Name -contains $section) -and $null -ne $user.$section) {
            foreach ($prop in $user.$section.PSObject.Properties) {
                $merged[$prop.Name] = $prop.Value
            }
        }
        $cfg | Add-Member -NotePropertyName $section -NotePropertyValue ([pscustomobject]$merged)
    }

    if ([string]::IsNullOrWhiteSpace(($cfg.agent.denyPatterns -join ''))) {
        $cfg.agent.denyPatterns = @()
    }
    return $cfg
}

function ConvertFrom-AgentSecureString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Security.SecureString]$SecureValue
    )

    return [System.Net.NetworkCredential]::new('', $SecureValue).Password
}

function Get-AgentSecret {
    <#
    .SYNOPSIS
        Keep secrets out of config files. Reads the env var named in the config;
        falls back to the OS-protected Clixml store in ~/.agent/secrets.xml.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$EnvName
    )

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if ($envValue) {
        return $envValue
    }

    $store = Join-Path -Path $HOME -ChildPath '.agent/secrets.xml'
    if (Test-Path -LiteralPath $store) {
        try {
            $loaded = Import-Clixml -LiteralPath $store
            if ($loaded -is [System.Collections.IDictionary]) {
                if ($loaded.Contains($EnvName)) {
                    $val = $loaded[$EnvName]
                    if ($val -is [System.Security.SecureString]) {
                        return (ConvertFrom-AgentSecureString -SecureValue $val)
                    }
                    return [string]$val
                }
            }
            else {
                foreach ($entry in @($loaded)) {
                    if ($null -eq $entry) { continue }
                    if (($entry.PSObject.Properties.Name -contains 'UserName') -and ($entry.UserName -eq $EnvName)) {
                        if ($entry.Password -is [System.Security.SecureString]) {
                            return (ConvertFrom-AgentSecureString -SecureValue $entry.Password)
                        }
                        return [string]$entry.Password
                    }
                }
            }
        }
        catch {
            Write-Verbose -Message "Could not read credential store '$store': $($_.Exception.Message)"
        }
    }
    return $null
}
