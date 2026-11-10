<#
.SYNOPSIS
    OpenAI-compatible chat completions client with retry/backoff.
.DESCRIPTION
    Works against OpenAI, Azure OpenAI, OpenRouter, Groq, Together, Ollama, LM Studio, and vLLM.
#>

function Get-MessageProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return [pscustomobject]@{ Found = $true; Value = $Object[$Name] }
        }
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    if ($null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)) {
        return [pscustomobject]@{ Found = $true; Value = $Object.$Name }
    }
    return [pscustomobject]@{ Found = $false; Value = $null }
}

function ConvertTo-LlmMessage {
    <#
    .SYNOPSIS
        Normalises internal message hashtables or deserialized PSCustomObjects into the wire shape.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Message
    )

    $roleRes = Get-MessageProperty -Object $Message -Name 'role'
    $out = [ordered]@{ role = [string]$roleRes.Value }

    $contentRes = Get-MessageProperty -Object $Message -Name 'content'
    if ($contentRes.Found) {
        $out.content = $contentRes.Value
    }

    $tcRes = Get-MessageProperty -Object $Message -Name 'tool_calls'
    if ($tcRes.Found -and $tcRes.Value) {
        $out.tool_calls = @($tcRes.Value | ForEach-Object {
                [ordered]@{
                    id       = $_.id
                    type     = 'function'
                    function = [ordered]@{
                        name      = $_.function.name
                        arguments = [string]$_.function.arguments
                    }
                }
            })
        if ($null -eq $out.content) {
            $out.content = ''
        }
    }

    $tcIdRes = Get-MessageProperty -Object $Message -Name 'tool_call_id'
    if ($tcIdRes.Found) {
        $out.tool_call_id = $tcIdRes.Value
    }

    return [pscustomobject]$out
}

function Invoke-ChatCompletion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI retry/dry-run status feedback')]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$Messages,
        [object[]]$Tools,
        [string]$ApiKey,
        [switch]$DryRun
    )

    $p = $Config.provider
    $endpoint = ($p.baseUrl.TrimEnd('/')) + '/chat/completions'
    $wire = @($Messages | ForEach-Object { ConvertTo-LlmMessage -Message $_ })

    $body = [ordered]@{
        model    = $p.model
        messages = $wire
        stream   = $false
    }
    if ($Tools -and $Tools.Count -gt 0) {
        $body.tools = $Tools
        $body.tool_choice = 'auto'
    }
    if ($p.maxTokens -gt 0) {
        $body[$p.maxTokensParam] = [int]$p.maxTokens
    }
    if ($null -ne $p.temperature -and $p.temperature -ge 0) {
        $body.temperature = [double]$p.temperature
    }

    $json = $body | ConvertTo-Json -Depth 30 -Compress

    if ($DryRun) {
        Write-Host -Object "[dry-run] POST $endpoint  ($($json.Length) bytes, $($wire.Count) messages)" -ForegroundColor DarkGray
        return [pscustomobject]@{
            choices = @([pscustomobject]@{
                    message = [pscustomobject]@{
                        content    = '[dry-run] model not called. The agent loop, config, prompt assembly and tool schemas all loaded correctly.'
                        tool_calls = $null
                    }
                })
            usage   = $null
        }
    }

    $headers = @{
        'Content-Type' = 'application/json'
    }
    if ($ApiKey) {
        $headers[$p.apiKeyHeader] = $p.apiKeyPrefix + $ApiKey
    }
    if ($null -ne $p.extraHeaders) {
        foreach ($h in $p.extraHeaders.PSObject.Properties) {
            $headers[$h.Name] = [string]$h.Value
        }
    }
    if ($p.name -eq 'azure' -and $ApiKey) {
        $headers['api-key'] = $ApiKey
        $headers.Remove('Authorization')
    }

    $attempt = 0
    $maxAttempts = [Math]::Max(1, [int]$p.maxRetries)
    $lastError = $null

    while ($attempt -lt $maxAttempts) {
        $attempt++
        try {
            $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $json `
                -ContentType 'application/json' -TimeoutSec ([int]$p.requestTimeoutSec)
            return $resp
        }
        catch {
            $lastError = $_
            $status = $null
            try {
                $status = [int]$_.Exception.Response.StatusCode
            }
            catch {
                Write-Verbose -Message 'HTTP status code unavailable on exception.'
            }

            # 4xx (except 429) will not fix themselves - surface them immediately.
            $retryable = ($null -eq $status) -or ($status -eq 429) -or ($status -ge 500)
            $detail = ''
            try {
                $stream = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($stream) { $detail = $stream }
            }
            catch {
                Write-Verbose -Message 'Response content stream unavailable.'
            }
            if (-not $detail) {
                $detail = $_.Exception.Message
            }

            if (-not $retryable -or $attempt -ge $maxAttempts) {
                throw "LLM request failed (HTTP $status) after $attempt attempt(s): $detail"
            }
            $wait = [Math]::Min(30, [Math]::Pow(2, $attempt)) + (Get-Random -Maximum 3)
            Write-Host -Object "  ! HTTP $status - retry $attempt/$maxAttempts in ${wait}s" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
    throw "LLM request failed: $($lastError.Exception.Message)"
}
