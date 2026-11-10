<#
.SYNOPSIS
    AgentTools.ps1 - the tool registry for PowerShell and .NET engineering.
.DESCRIPTION
    Every capability the model has lives here. A tool is:
        Description = when to use it
        Parameters  = JSON Schema
        Script      = scriptblock receiving -ToolArgs (hashtable) and returning
                      [pscustomobject]@{ ok = [bool]; output = [string] }
#>

$script:KitDir = $PSScriptRoot

# ------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------

function Resolve-AgentPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is required' }
    $root = $script:Workspace

    if ([System.IO.Path]::IsPathRooted($Path)) {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    else {
        $full = [System.IO.Path]::GetFullPath((Join-Path -Path $root -ChildPath $Path))
    }

    $normRoot = [System.IO.Path]::GetFullPath($root).TrimEnd('/', '\')
    $rootWithSep = $normRoot + [System.IO.Path]::DirectorySeparatorChar
    $cmp = if ($IsWindows -or $env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $inside = $full.Equals($normRoot, $cmp) -or $full.StartsWith($rootWithSep, $cmp)

    if (-not $inside) {
        if (-not $script:Cfg.agent.allowOutsideWorkspace) {
            throw "Path escapes the workspace: $Path (workspace guard is on; set agent.allowOutsideWorkspace=true to permit)"
        }
    }
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $full)) {
        throw "Path not found: $Path"
    }
    return $full
}

function Get-RelativeWorkspacePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$FullPath
    )

    $rel = [System.IO.Path]::GetRelativePath($script:Workspace, $FullPath)
    return ($rel -replace '\\', '/')
}

function Get-Arg {
    [CmdletBinding()]
    param(
        $ToolArgs,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if (-not $ToolArgs) { return $Default }
    $has = $false
    try { $has = $ToolArgs.Keys -contains $Name } catch { $has = $false }
    if ($has -and $null -ne $ToolArgs[$Name]) { return $ToolArgs[$Name] }
    return $Default
}

function Split-ArgumentString {
    <#
    .SYNOPSIS
        Splits an extra-arguments string into tokens while respecting quoted spans.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$InputText)

    if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }
    $tokens = [System.Collections.Generic.List[string]]::new()
    $rx = [regex]'[^\s"''"]+|"([^"]*)"|''([^'']*)'''
    # Handle mixed key="value" tokens like -p:Authors="Jane Doe" cleanly:
    $sb = [System.Text.StringBuilder]::new()
    $quote = [char]0
    foreach ($ch in $InputText.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 }
            else { [void]$sb.Append($ch) }
        }
        elseif ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
        }
        elseif ([char]::IsWhiteSpace($ch)) {
            if ($sb.Length -gt 0) {
                $tokens.Add($sb.ToString())
                [void]$sb.Clear()
            }
        }
        else {
            [void]$sb.Append($ch)
        }
    }
    if ($sb.Length -gt 0) { $tokens.Add($sb.ToString()) }
    $null = $rx
    return $tokens.ToArray()
}

function Format-UnifiedDiff {
    <#
    .SYNOPSIS
        Line diff with LCS so approval prompts show exact proposed edits.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$OldText = '',
        [string]$NewText = '',
        [string]$Path = 'file',
        [int]$Context = 3
    )

    $a = @($OldText -split "`r?`n")
    $b = @($NewText -split "`r?`n")
    $n = $a.Count
    $m = $b.Count

    if ($n * $m -gt 4000000) {
        return "--- $Path`n+++ $Path`n(file too large for inline diff: $n -> $m lines)"
    }
    $lcs = New-Object -TypeName 'int[,]' -ArgumentList ($n + 1), ($m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($a[$i] -ceq $b[$j]) { $lcs[$i, $j] = $lcs[($i + 1), ($j + 1)] + 1 }
            else { $lcs[$i, $j] = [Math]::Max($lcs[($i + 1), $j], $lcs[$i, ($j + 1)]) }
        }
    }
    $ops = [System.Collections.Generic.List[object]]::new()
    $x = 0
    $y = 0
    while ($x -lt $n -and $y -lt $m) {
        if ($a[$x] -ceq $b[$y]) { $ops.Add([pscustomobject]@{ t = ' '; line = $a[$x] }); $x++; $y++ }
        elseif ($lcs[($x + 1), $y] -ge $lcs[$x, ($y + 1)]) { $ops.Add([pscustomobject]@{ t = '-'; line = $a[$x] }); $x++ }
        else { $ops.Add([pscustomobject]@{ t = '+'; line = $b[$y] }); $y++ }
    }
    while ($x -lt $n) { $ops.Add([pscustomobject]@{ t = '-'; line = $a[$x] }); $x++ }
    while ($y -lt $m) { $ops.Add([pscustomobject]@{ t = '+'; line = $b[$y] }); $y++ }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("--- $Path (current)")
    [void]$sb.AppendLine("+++ $Path (proposed)")

    $added = @($ops | Where-Object { $_.t -eq '+' }).Count
    $removed = @($ops | Where-Object { $_.t -eq '-' }).Count
    [void]$sb.AppendLine("@@ $added added, $removed removed @@")

    $skipUntil = -1
    for ($k = 0; $k -lt $ops.Count; $k++) {
        $op = $ops[$k]
        if ($op.t -ne ' ') { [void]$sb.AppendLine($op.t + $op.line); continue }
        $nearChange = $false
        for ($d = [Math]::Max(0, $k - $Context); $d -lt [Math]::Min($ops.Count, $k + $Context + 1); $d++) {
            if ($ops[$d].t -ne ' ') { $nearChange = $true; break }
        }
        if ($nearChange) { [void]$sb.AppendLine(' ' + $op.line) }
        elseif ($k -gt $skipUntil) { [void]$sb.AppendLine(' ...'); $skipUntil = $k + 1 }
    }
    return $sb.ToString()
}

function Resolve-PwshPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @($script:Cfg.agent.pwshPath)
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $candidates += @('C:\Program Files\PowerShell\7\pwsh.exe', 'pwsh.exe')
    }
    else {
        $candidates += @('/usr/bin/pwsh', '/usr/local/bin/pwsh', '/opt/microsoft/powershell/7/pwsh', (Join-Path -Path $HOME -ChildPath '.local/pwsh/pwsh'))
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $cmd = Get-Command -Name $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Resolve-DotnetPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $c = Get-Command -Name $script:Cfg.agent.dotnetPath -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'C:\Program Files\dotnet\dotnet.exe' } else { Join-Path -Path $HOME -ChildPath '.local/dotnet/dotnet' }
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $script:Cfg.agent.dotnetPath
}

function Invoke-CapturedProcess {
    <#
    .SYNOPSIS
        Runs an executable with args, captures stdout+stderr, and enforces a timeout without shell injection.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSec = 300,
        [hashtable]$Environment = @{}
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $false
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { $script:Workspace }
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] }

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()

    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $p.Kill($true) } catch { Write-Verbose -Message "Process kill ignored: $($_.Exception.Message)" }
        $sw.Stop()
        return [pscustomobject]@{
            exitCode = 124
            output   = ($outTask.Result + "`n" + $errTask.Result) + "`n[agent] TIMEOUT after ${TimeoutSec}s - process killed."
            duration = $sw.Elapsed.TotalSeconds
            timedOut = $true
        }
    }
    $p.WaitForExit()
    $sw.Stop()

    $stdout = $outTask.Result
    $stderr = $errTask.Result
    $combined = $stdout
    if ($stderr) { $combined = ($stdout + "`n" + $stderr).Trim() }

    return [pscustomobject]@{
        exitCode = $p.ExitCode
        output   = $combined
        duration = $sw.Elapsed.TotalSeconds
        timedOut = $false
    }
}

# ------------------------------------------------------------------------------
# registry
# ------------------------------------------------------------------------------

function New-AgentToolRegistry {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'AskUser tool prompts the interactive user in terminal')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory tool registry')]
    param()

    $reg = [ordered]@{}

    # ---------------------------------------------------------------- read ----
    $reg['ReadFile'] = @{
        Description = 'Read a text file from the workspace. Use before editing anything. Returns lines with 1-based line numbers.'
        Parameters  = @{
            type = 'object'; required = @('path')
            properties = @{
                path       = @{ type = 'string'; description = 'Workspace-relative or absolute path.' }
                start_line = @{ type = 'integer'; description = 'First line (1-based). Optional.' }
                max_lines  = @{ type = 'integer'; description = 'Max lines to return. Default 400.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $p = Resolve-AgentPath -Path (Get-Arg -ToolArgs $ToolArgs -Name 'path')
            $start = [int](Get-Arg -ToolArgs $ToolArgs -Name 'start_line' -Default 1)
            $max = [int](Get-Arg -ToolArgs $ToolArgs -Name 'max_lines' -Default 400)
            $all = [System.IO.File]::ReadAllLines($p)
            $total = $all.Count
            $slice = $all | Select-Object -Skip ($start - 1) -First $max
            $rel = Get-RelativeWorkspacePath -FullPath $p
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("<file path=""$rel"" total_lines=""$total"" showing_from=""$start"">")
            $i = $start
            foreach ($l in $slice) {
                [void]$sb.AppendLine(('{0,5}| {1}' -f $i, $l))
                $i++
            }
            [void]$sb.AppendLine('</file>')
            [pscustomobject]@{ ok = $true; output = $sb.ToString() }
        }
    }

    # --------------------------------------------------------------- write ----
    $reg['WriteFile'] = @{
        Description = 'Create a file or replace its entire contents. Use for new files. For edits to existing files prefer EditFile so the change stays minimal.'
        Parameters  = @{
            type = 'object'; required = @('path', 'content')
            properties = @{
                path      = @{ type = 'string' }
                content   = @{ type = 'string'; description = 'Full file content. Use \n newlines; do not include line numbers.' }
                overwrite = @{ type = 'boolean'; description = 'Required true to replace an existing file. Default false.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $raw = [string](Get-Arg -ToolArgs $ToolArgs -Name 'path')
            $p = Resolve-AgentPath -Path $raw -AllowMissing
            $content = [string](Get-Arg -ToolArgs $ToolArgs -Name 'content' -Default '')
            $exists = Test-Path -LiteralPath $p
            if ($exists -and -not (Get-Arg -ToolArgs $ToolArgs -Name 'overwrite' -Default $false)) {
                return [pscustomobject]@{ ok = $false; output = "ERROR: '$raw' already exists. Use EditFile for changes, or pass overwrite=true to replace it wholesale." }
            }
            $content = $content -replace "`r`n", "`n"
            $dir = Split-Path -Parent $p
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllText($p, $content, [System.Text.UTF8Encoding]::new($false))
            $lines = ($content -split "`n").Count
            [pscustomobject]@{ ok = $true; output = "Wrote $raw ($lines lines, $($content.Length) chars)." }
        }
    }

    # ---------------------------------------------------------------- edit ----
    $reg['EditFile'] = @{
        Description = 'Replace exactly one occurrence of old_text with new_text in a file. old_text must be unique enough to identify the spot - include 2-4 lines of surrounding context. This is the preferred editing tool.'
        Parameters  = @{
            type = 'object'; required = @('path', 'old_text', 'new_text')
            properties = @{
                path        = @{ type = 'string' }
                old_text    = @{ type = 'string'; description = 'Exact existing text, including indentation.' }
                new_text    = @{ type = 'string'; description = 'Replacement text.' }
                replace_all = @{ type = 'boolean'; description = 'Replace every occurrence. Default false.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $raw = [string](Get-Arg -ToolArgs $ToolArgs -Name 'path')
            $p = Resolve-AgentPath -Path $raw
            $old = [string](Get-Arg -ToolArgs $ToolArgs -Name 'old_text' -Default '')
            $new = [string](Get-Arg -ToolArgs $ToolArgs -Name 'new_text' -Default '')
            $all = [bool](Get-Arg -ToolArgs $ToolArgs -Name 'replace_all' -Default $false)

            if ([string]::IsNullOrEmpty($old)) { return [pscustomobject]@{ ok = $false; output = 'ERROR: old_text is empty.' } }

            $text = [System.IO.File]::ReadAllText($p)
            $crlf = $text.Contains("`r`n")
            $norm = $text -replace "`r`n", "`n"
            $oldN = $old -replace "`r`n", "`n"
            $newN = $new -replace "`r`n", "`n"

            $count = ([regex]::Matches($norm, [regex]::Escape($oldN))).Count
            if ($count -eq 0) {
                $pattern = ($oldN -split "`n" | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '\s*\n\s*'
                $m = [regex]::Match($norm, $pattern)
                if (-not $m.Success) {
                    return [pscustomobject]@{ ok = $false; output = "ERROR: old_text not found in $raw. Read the file again and copy the exact text." }
                }
                $norm = $norm.Remove($m.Index, $m.Length).Insert($m.Index, $newN)
                $count = 1
            }
            elseif ($count -gt 1 -and -not $all) {
                return [pscustomobject]@{ ok = $false; output = "ERROR: old_text matches $count places in $raw. Add surrounding context, or pass replace_all=true." }
            }
            else {
                if ($all) { $norm = $norm.Replace($oldN, $newN) }
                else {
                    $idx = $norm.IndexOf($oldN, [StringComparison]::Ordinal)
                    $norm = $norm.Remove($idx, $oldN.Length).Insert($idx, $newN)
                }
            }

            if ($crlf) { $norm = $norm -replace "`n", "`r`n" }
            [System.IO.File]::WriteAllText($p, $norm, [System.Text.UTF8Encoding]::new($false))
            [pscustomobject]@{ ok = $true; output = "Edited $raw ($count replacement(s))." }
        }
    }

    # ---------------------------------------------------------------- list ----
    $reg['ListFiles'] = @{
        Description = 'List files and directories in the workspace as a tree. Use to orient yourself before planning.'
        Parameters  = @{
            type       = 'object'
            properties = @{
                path      = @{ type = 'string'; description = 'Directory, default workspace root.' }
                pattern   = @{ type = 'string'; description = 'Wildcard filter, e.g. *.ps1 or *.cs. Default *.' }
                max_depth = @{ type = 'integer'; description = 'Default 3.' }
                max_items = @{ type = 'integer'; description = 'Default 300.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $dirArg = Get-Arg -ToolArgs $ToolArgs -Name 'path'
            $root = if ($dirArg) { Resolve-AgentPath -Path $dirArg } else { $script:Workspace }
            $pattern = [string](Get-Arg -ToolArgs $ToolArgs -Name 'pattern' -Default '*')
            $depth = [int](Get-Arg -ToolArgs $ToolArgs -Name 'max_depth' -Default 3)
            $maxItems = [int](Get-Arg -ToolArgs $ToolArgs -Name 'max_items' -Default 300)
            $skip = @('node_modules', 'bin', 'obj', '.git', '.vs', 'packages', 'TestResults', '.agent', 'artifacts')

            $results = [System.Collections.Generic.List[string]]::new()
            $walk = $null
            $walk = {
                param($dir, $level)
                if ($level -gt $depth) { return }
                $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                    Where-Object { $skip -notcontains $_.Name } |
                    Sort-Object -Property @{ Expression = { -not $_.PSIsContainer } }, Name
                foreach ($it in $items) {
                    if ($results.Count -ge $maxItems) { return }
                    if ($it.PSIsContainer) {
                        $results.Add(('  ' * $level) + $it.Name + '/')
                        & $walk $it.FullName ($level + 1)
                    }
                    elseif ($pattern -eq '*' -or $it.Name -like $pattern) {
                        $results.Add(('  ' * $level) + ('{0}  ({1} B)' -f $it.Name, $it.Length))
                    }
                }
            }
            & $walk $root 0
            $out = if ($results.Count) { $results -join "`n" } else { '(no matching files)' }
            if ($results.Count -ge $maxItems) { $out += "`n...[capped at $maxItems items]" }
            [pscustomobject]@{ ok = $true; output = $out }
        }
    }

    # -------------------------------------------------------------- search ----
    $reg['SearchCode'] = @{
        Description = 'Regex search across workspace files. Returns file:line:match. Use to find usages before changing an API.'
        Parameters  = @{
            type = 'object'; required = @('pattern')
            properties = @{
                pattern     = @{ type = 'string'; description = '.NET regex.' }
                path        = @{ type = 'string'; description = 'Subdirectory to search. Default workspace.' }
                file_glob   = @{ type = 'string'; description = 'e.g. *.ps1,*.psm1,*.cs' }
                max_results = @{ type = 'integer'; description = 'Default 100.' }
                ignore_case = @{ type = 'boolean'; description = 'Default true.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $pat = [string](Get-Arg -ToolArgs $ToolArgs -Name 'pattern')
            if (-not $pat) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pattern required' } }
            $dirArg = Get-Arg -ToolArgs $ToolArgs -Name 'path'
            $root = if ($dirArg) { Resolve-AgentPath -Path $dirArg } else { $script:Workspace }
            $globs = @(([string](Get-Arg -ToolArgs $ToolArgs -Name 'file_glob' -Default '*.ps1,*.psm1,*.psd1,*.cs,*.csproj,*.json,*.md,*.ps1xml,*.yml,*.props')) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $max = [int](Get-Arg -ToolArgs $ToolArgs -Name 'max_results' -Default 100)
            $opts = if (Get-Arg -ToolArgs $ToolArgs -Name 'ignore_case' -Default $true) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }
            $rx = [regex]::new($pat, $opts)
            $skipRx = '(?:^|[\\/])(node_modules|bin|obj|\.git|\.vs|\.agent|TestResults|artifacts)(?:[\\/]|$)'

            $hits = [System.Collections.Generic.List[string]]::new()
            $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -notmatch $skipRx -and
                    $_.Length -lt 2MB
                } | Where-Object {
                    $fileName = $_.Name
                    foreach ($g in $globs) {
                        if ($fileName -like $g) { return $true }
                    }
                    return $false
                }

            foreach ($f in $files) {
                $lineNo = 0
                foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                    $lineNo++
                    if ($rx.IsMatch($line)) {
                        $rel = Get-RelativeWorkspacePath -FullPath $f.FullName
                        $hits.Add(('{0}:{1}: {2}' -f $rel, $lineNo, $line.Trim()))
                        if ($hits.Count -ge $max) { break }
                    }
                }
                if ($hits.Count -ge $max) { break }
            }
            $out = if ($hits.Count) { $hits -join "`n" } else { 'No matches.' }
            [pscustomobject]@{ ok = $true; output = $out }
        }
    }

    # ------------------------------------------------------- execute a shell ----
    $reg['RunCommand'] = @{
        Description = 'Run a shell command in the workspace. Prefer the specific tools (RunBuild, RunTests, RunPwshAnalysis) when they apply. Use pwsh for PowerShell 7 scripts, powershell for Windows PowerShell 5.1 compatibility checks, bash for POSIX.'
        Parameters  = @{
            type = 'object'; required = @('command')
            properties = @{
                command     = @{ type = 'string'; description = 'The command line to execute.' }
                shell       = @{ type = 'string'; enum = @('pwsh', 'powershell', 'bash', 'cmd'); description = 'Default pwsh.' }
                working_dir = @{ type = 'string'; description = 'Relative to workspace. Default workspace root.' }
                timeout_sec = @{ type = 'integer'; description = 'Default from config.' }
                purpose     = @{ type = 'string'; description = 'One sentence: why this command is needed. Shown to the human at approval time.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $cmd = [string](Get-Arg -ToolArgs $ToolArgs -Name 'command')
            $shell = [string](Get-Arg -ToolArgs $ToolArgs -Name 'shell' -Default 'pwsh')
            $wdArg = Get-Arg -ToolArgs $ToolArgs -Name 'working_dir'
            $wd = if ($wdArg) { Resolve-AgentPath -Path $wdArg } else { $script:Workspace }
            $timeout = [int](Get-Arg -ToolArgs $ToolArgs -Name 'timeout_sec' -Default $script:CommandTimeout)

            switch ($shell) {
                'pwsh' {
                    $exe = Resolve-PwshPath
                    if (-not $exe) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found on this machine. Install PowerShell 7 or set agent.pwshPath in the config.' } }
                    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                'powershell' {
                    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                        return [pscustomobject]@{ ok = $false; output = 'ERROR: Windows PowerShell 5.1 is only available on Windows. Use pwsh for cross-version code, and validate 5.1 compatibility with RunPwshAnalysis -Target PowerShell51 (PSScriptAnalyzer flags 7-only syntax).' }
                    }
                    $exe = (Get-Command -Name $script:Cfg.agent.windowsPowerShellPath -ErrorAction SilentlyContinue).Source
                    if (-not $exe) { return [pscustomobject]@{ ok = $false; output = 'ERROR: powershell.exe not found on PATH.' } }
                    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                'bash' {
                    $exe = if (Test-Path -LiteralPath $script:Cfg.agent.posixShell) { $script:Cfg.agent.posixShell } else { '/bin/sh' }
                    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentList @('-c', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                'cmd' {
                    $r = Invoke-CapturedProcess -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -WorkingDirectory $wd -TimeoutSec $timeout
                }
                default { return [pscustomobject]@{ ok = $false; output = "ERROR: unsupported shell '$shell'" } }
            }

            $ok = ($r.exitCode -eq 0)
            [pscustomobject]@{
                ok     = $ok
                output = ("exit=$($r.exitCode) time=$([math]::Round($r.duration,1))s`n$($r.output)")
            }
        }
    }

    # ---------------------------------------------------------------- build ----
    $reg['RunBuild'] = @{
        Description = 'Build a .NET project or solution with the dotnet CLI. Returns compiler diagnostics verbatim. Run this after any C# change.'
        Parameters  = @{
            type       = 'object'
            properties = @{
                project                  = @{ type = 'string'; description = 'Path to .csproj/.sln/dir. Default: current directory.' }
                configuration            = @{ type = 'string'; enum = @('Debug', 'Release'); description = 'Default Debug.' }
                extra_args               = @{ type = 'string'; description = 'Extra msbuild args, e.g. "-p:LangVersion=latest".' }
                restore                  = @{ type = 'boolean'; description = 'Run restore first. Default true.' }
                no_incremental           = @{ type = 'boolean'; description = 'Force a full rebuild. Default false.' }
                treat_warnings_as_errors = @{ type = 'boolean'; description = 'Pass -warnaserror. Default false.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $dotnet = Resolve-DotnetPath
            $argList = [System.Collections.Generic.List[string]]::new()
            $argList.Add('build')
            $proj = Get-Arg -ToolArgs $ToolArgs -Name 'project'
            if ($proj) { $argList.Add((Resolve-AgentPath -Path $proj -AllowMissing)) }
            $argList.Add('-c'); $argList.Add([string](Get-Arg -ToolArgs $ToolArgs -Name 'configuration' -Default 'Debug'))
            if (Get-Arg -ToolArgs $ToolArgs -Name 'no_incremental' -Default $false) { $argList.Add('--no-incremental') }
            if (-not (Get-Arg -ToolArgs $ToolArgs -Name 'restore' -Default $true)) { $argList.Add('--no-restore') }
            if (Get-Arg -ToolArgs $ToolArgs -Name 'treat_warnings_as_errors' -Default $false) { $argList.Add('-warnaserror') }
            $argList.Add('-v'); $argList.Add('minimal')
            $argList.Add('-nologo')
            $extra = Get-Arg -ToolArgs $ToolArgs -Name 'extra_args'
            foreach ($x in (Split-ArgumentString -InputText $extra)) { $argList.Add($x) }

            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $argList.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{
                ok     = ($r.exitCode -eq 0)
                output = ("dotnet $($argList -join ' ')`nexit=$($r.exitCode)`n$($r.output)")
            }
        }
    }

    # ---------------------------------------------------------------- tests ----
    $reg['RunTests'] = @{
        Description = 'Run tests. kind=pester runs Invoke-Pester on the given path; kind=dotnet runs dotnet test.'
        Parameters  = @{
            type       = 'object'
            properties = @{
                kind     = @{ type = 'string'; enum = @('pester', 'dotnet'); description = 'Default pester.' }
                path     = @{ type = 'string'; description = 'Test file/dir (pester) or project (dotnet). Default the tests/ folder or workspace.' }
                filter   = @{ type = 'string'; description = 'Pester -FullNameFilter / dotnet --filter expression.' }
                coverage = @{ type = 'boolean'; description = 'Enable code coverage output. Default false.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $kind = [string](Get-Arg -ToolArgs $ToolArgs -Name 'kind' -Default 'pester')

            if ($kind -eq 'dotnet') {
                $dotnet = Resolve-DotnetPath
                $a = [System.Collections.Generic.List[string]]::new()
                $a.Add('test')
                $pArg = Get-Arg -ToolArgs $ToolArgs -Name 'path'
                if ($pArg) { $a.Add((Resolve-AgentPath -Path $pArg -AllowMissing)) }
                $a.Add('--nologo')
                $a.Add('-v'); $a.Add('minimal')
                $flt = Get-Arg -ToolArgs $ToolArgs -Name 'filter'
                if ($flt) { $a.Add('--filter'); $a.Add([string]$flt) }
                if (Get-Arg -ToolArgs $ToolArgs -Name 'coverage' -Default $false) {
                    $a.Add('--collect:XPlat Code Coverage')
                    $a.Add('--results-directory'); $a.Add((Join-Path -Path $script:Workspace -ChildPath 'artifacts/test-results'))
                }
                $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
                return [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
            }

            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }
            $pArg = Get-Arg -ToolArgs $ToolArgs -Name 'path'
            $target = if ($pArg) { Resolve-AgentPath -Path $pArg } else {
                $t = Join-Path -Path $script:Workspace -ChildPath 'tests'
                if (Test-Path -LiteralPath $t) { $t } else { $script:Workspace }
            }
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine('Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop')
            [void]$sb.AppendLine('$config = New-PesterConfiguration')
            [void]$sb.AppendLine(('$config.Run.Path = @(''{0}'')' -f ($target -replace '''', '''''')))
            [void]$sb.AppendLine('$config.Output.Verbosity = ''Normal''')
            [void]$sb.AppendLine('$config.Run.PassThru = $true')
            $flt = Get-Arg -ToolArgs $ToolArgs -Name 'filter'
            if ($flt) { [void]$sb.AppendLine(('$config.Filter.FullName = @(''{0}'')' -f ([string]$flt -replace '''', ''''''))) }
            if (Get-Arg -ToolArgs $ToolArgs -Name 'coverage' -Default $false) {
                $src = Join-Path -Path $script:Workspace -ChildPath 'src'
                if (Test-Path -LiteralPath $src) {
                    [void]$sb.AppendLine('$config.CodeCoverage.Enabled = $true')
                    [void]$sb.AppendLine(('$config.CodeCoverage.Path = @(''{0}'')' -f ($src -replace '''', '''''')))
                }
            }
            [void]$sb.AppendLine('$res = Invoke-Pester -Configuration $config')
            [void]$sb.AppendLine('"PASSED=$($res.PassedCount) FAILED=$($res.FailedCount) SKIPPED=$($res.SkippedCount)"')
            [void]$sb.AppendLine('if ($res.FailedCount -gt 0) { exit 1 }')

            $tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('pester-' + [guid]::NewGuid() + '.ps1')
            [System.IO.File]::WriteAllText($tmp, $sb.ToString())
            try {
                $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $tmp) -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            }
            finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }

            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("Invoke-Pester -Path '$target'`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    # ------------------------------------------------------------- analysis ----
    $reg['RunPwshAnalysis'] = @{
        Description = 'Run PSScriptAnalyzer against a script/module and report rule violations. With target=PowerShell51 or Both it additionally flags syntax that breaks Windows PowerShell 5.1.'
        Parameters  = @{
            type = 'object'; required = @('path')
            properties = @{
                path     = @{ type = 'string'; description = 'File or directory to analyse.' }
                target   = @{ type = 'string'; enum = @('PowerShell51', 'PowerShell7', 'Both'); description = 'Compatibility target. Default Both.' }
                severity = @{ type = 'string'; enum = @('Error', 'Warning', 'Information', 'ParseError'); description = 'Minimum severity. Default Warning.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $p = Resolve-AgentPath -Path (Get-Arg -ToolArgs $ToolArgs -Name 'path')
            $target = [string](Get-Arg -ToolArgs $ToolArgs -Name 'target' -Default 'Both')
            $sev = [string](Get-Arg -ToolArgs $ToolArgs -Name 'severity' -Default 'Warning')
            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }

            $settingsFile = Join-Path -Path $script:Workspace -ChildPath '.vscode/PSScriptAnalyzerSettings.psd1'
            $hasSettings = Test-Path -LiteralPath $settingsFile

            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine('$ErrorActionPreference = ''Stop''')
            [void]$sb.AppendLine('if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Write-Output ''ERROR: PSScriptAnalyzer module is not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser''; exit 2 }')
            [void]$sb.AppendLine('Import-Module PSScriptAnalyzer')
            $escapedPath = $p -replace '''', ''''''
            if ($hasSettings) {
                $escapedSettings = $settingsFile -replace '''', ''''''
                [void]$sb.AppendLine("`$r = @(Invoke-ScriptAnalyzer -Path '$escapedPath' -Recurse -Severity '$sev' -Settings '$escapedSettings')")
            }
            else {
                [void]$sb.AppendLine('$settings = @{ IncludeRules = @(''PSUseCompatibleSyntax'',''PSAvoidUsingWriteHost'',''PSUseApprovedVerbs'',''PSAvoidUsingInvokeExpression'',''PSAvoidGlobalVars'',''PSUseSingularNouns'',''PSAvoidUsingPositionalParameters'',''PSAvoidAssignmentToAutomaticVariable''); Severity = @(''Error'',''Warning'',''Information'',''ParseError'') }')
                [void]$sb.AppendLine("`$r = @(Invoke-ScriptAnalyzer -Path '$escapedPath' -Recurse -Severity '$sev' -Settings `$settings)")
            }
            if ($target -in @('PowerShell51', 'Both')) {
                [void]$sb.AppendLine("`$compat = @(Invoke-ScriptAnalyzer -Path '$escapedPath' -Recurse -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = `$true; TargetVersions = @('5.1','7.0') } } } -ErrorAction SilentlyContinue)")
                [void]$sb.AppendLine('$r = @($r) + @($compat)')
            }
            [void]$sb.AppendLine('$r = @($r | Where-Object { $_ } | Sort-Object ScriptName, Line, RuleName -Unique)')
            [void]$sb.AppendLine('if ($r.Count -eq 0) { Write-Output ''CLEAN: no violations.''; exit 0 }')
            [void]$sb.AppendLine('$errs = @($r | Where-Object { $_.Severity -in @(''Error'',''ParseError'') }).Count')
            [void]$sb.AppendLine('$r | ForEach-Object { "{0}:{1} [{2}] {3} - {4}" -f ($_.ScriptName -replace [regex]::Escape($PWD.Path + [IO.Path]::DirectorySeparatorChar), ''''), $_.Line, $_.Severity, $_.RuleName, $_.Message }')
            [void]$sb.AppendLine('Write-Output ""')
            [void]$sb.AppendLine('Write-Output "TOTAL=$($r.Count) ERRORS=$errs"')
            [void]$sb.AppendLine('if ($errs -gt 0) { exit 1 }')

            $tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('psa-' + [guid]::NewGuid() + '.ps1')
            [System.IO.File]::WriteAllText($tmp, $sb.ToString())
            try {
                $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $tmp) -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            }
            finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("PSScriptAnalyzer target=$target path=$p`n$($r.output)") }
        }
    }

    # -------------------------------------------------------------- inspect ----
    $reg['InspectPowerShell'] = @{
        Description = 'Ask the local PowerShell for ground truth: resolve a command, its parameters, type members, or see available modules. Use this instead of guessing an API.'
        Parameters  = @{
            type = 'object'; required = @('query')
            properties = @{
                query = @{ type = 'string'; description = 'PowerShell expression to evaluate read-only, e.g. "Get-Command Invoke-RestMethod -Syntax" or "[System.IO.File] | Get-Member -Static".' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $q = [string](Get-Arg -ToolArgs $ToolArgs -Name 'query')
            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }
            $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $q) -WorkingDirectory $script:Workspace -TimeoutSec 120
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = $r.output }
        }
    }

    # ----------------------------------------------------------- scaffolds ----
    $reg['DotnetNew'] = @{
        Description = 'Scaffold a new .NET project with dotnet new. Templates: classlib, console, xunit, nunit, mstest, web, webapi, worker, sln, gitignore, editorconfig, nugetconfig.'
        Parameters  = @{
            type = 'object'; required = @('template', 'name')
            properties = @{
                template   = @{ type = 'string' }
                name       = @{ type = 'string' }
                output     = @{ type = 'string'; description = 'Output directory. Default ./src/<name>.' }
                framework  = @{ type = 'string'; description = 'e.g. net9.0, net8.0, netstandard2.0' }
                extra_args = @{ type = 'string' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $tpl = [string](Get-Arg -ToolArgs $ToolArgs -Name 'template')
            $name = [string](Get-Arg -ToolArgs $ToolArgs -Name 'name')
            $out = [string](Get-Arg -ToolArgs $ToolArgs -Name 'output' -Default (Join-Path -Path 'src' -ChildPath $name))
            $dotnet = Resolve-DotnetPath
            $a = [System.Collections.Generic.List[string]]::new()
            $a.Add('new'); $a.Add($tpl); $a.Add('-n'); $a.Add($name); $a.Add('-o'); $a.Add((Resolve-AgentPath -Path $out -AllowMissing))
            $fw = Get-Arg -ToolArgs $ToolArgs -Name 'framework'
            if ($fw) { $a.Add('-f'); $a.Add([string]$fw) }
            foreach ($x in (Split-ArgumentString -InputText (Get-Arg -ToolArgs $ToolArgs -Name 'extra_args' -Default ''))) { $a.Add($x) }
            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    $reg['AddPackage'] = @{
        Description = 'Add a NuGet package reference to a project.'
        Parameters  = @{
            type = 'object'; required = @('project', 'package')
            properties = @{
                project = @{ type = 'string' }
                package = @{ type = 'string' }
                version = @{ type = 'string' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $dotnet = Resolve-DotnetPath
            $a = @('add', (Resolve-AgentPath -Path (Get-Arg -ToolArgs $ToolArgs -Name 'project')), 'package', [string](Get-Arg -ToolArgs $ToolArgs -Name 'package'))
            $ver = Get-Arg -ToolArgs $ToolArgs -Name 'version'
            if ($ver) { $a += @('--version', [string]$ver) }
            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    # -------------------------------------------------- enterprise .NET ----
    $reg['DotnetSolution'] = @{
        Description = 'Manage .NET solutions, project references, package vulnerability audits, and formatting verification.'
        Parameters  = @{
            type = 'object'; required = @('action')
            properties = @{
                action    = @{ type = 'string'; enum = @('list', 'add-project', 'remove-project', 'add-reference', 'audit-packages', 'format-verify') }
                solution  = @{ type = 'string'; description = 'Path to .sln/.slnx file.' }
                project   = @{ type = 'string'; description = 'Target .csproj file.' }
                reference = @{ type = 'string'; description = 'Referenced .csproj for add-reference.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $dotnet = Resolve-DotnetPath
            $action = [string](Get-Arg -ToolArgs $ToolArgs -Name 'action')
            $sln = Get-Arg -ToolArgs $ToolArgs -Name 'solution'
            $proj = Get-Arg -ToolArgs $ToolArgs -Name 'project'
            $ref = Get-Arg -ToolArgs $ToolArgs -Name 'reference'

            $a = switch ($action) {
                'list' {
                    if (-not $sln) { return [pscustomobject]@{ ok = $false; output = 'ERROR: solution is required.' } }
                    @('sln', (Resolve-AgentPath -Path $sln), 'list')
                }
                'add-project' {
                    if (-not $sln -or -not $proj) { return [pscustomobject]@{ ok = $false; output = 'ERROR: solution and project are required.' } }
                    @('sln', (Resolve-AgentPath -Path $sln), 'add', (Resolve-AgentPath -Path $proj))
                }
                'remove-project' {
                    if (-not $sln -or -not $proj) { return [pscustomobject]@{ ok = $false; output = 'ERROR: solution and project are required.' } }
                    @('sln', (Resolve-AgentPath -Path $sln), 'remove', (Resolve-AgentPath -Path $proj))
                }
                'add-reference' {
                    if (-not $proj -or -not $ref) { return [pscustomobject]@{ ok = $false; output = 'ERROR: project and reference are required.' } }
                    @('add', (Resolve-AgentPath -Path $proj), 'reference', (Resolve-AgentPath -Path $ref))
                }
                'audit-packages' {
                    $target = if ($sln) { Resolve-AgentPath -Path $sln } elseif ($proj) { Resolve-AgentPath -Path $proj } else { $script:Workspace }
                    @('list', $target, 'package', '--vulnerable', '--include-transitive')
                }
                'format-verify' {
                    $target = if ($sln) { Resolve-AgentPath -Path $sln } elseif ($proj) { Resolve-AgentPath -Path $proj } else { $script:Workspace }
                    @('format', $target, '--verify-no-changes', '--verbosity', 'diagnostic')
                }
                default { return [pscustomobject]@{ ok = $false; output = "ERROR: unsupported action '$action'" } }
            }
            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    $reg['DotnetPackPublish'] = @{
        Description = 'Create NuGet packages (dotnet pack) or release outputs (dotnet publish) into ./artifacts without pushing remotely.'
        Parameters  = @{
            type = 'object'; required = @('action', 'project')
            properties = @{
                action         = @{ type = 'string'; enum = @('pack', 'publish') }
                project        = @{ type = 'string'; description = 'Path to .csproj or .sln.' }
                configuration  = @{ type = 'string'; enum = @('Release', 'Debug'); description = 'Default Release.' }
                output         = @{ type = 'string'; description = 'Output dir inside workspace. Default ./artifacts/nupkg or ./artifacts/publish.' }
                runtime        = @{ type = 'string'; description = 'Optional RID for publish, e.g. win-x64 or linux-x64.' }
                self_contained = @{ type = 'boolean'; description = 'Publish self-contained. Default false.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $dotnet = Resolve-DotnetPath
            $action = [string](Get-Arg -ToolArgs $ToolArgs -Name 'action')
            $proj = Resolve-AgentPath -Path (Get-Arg -ToolArgs $ToolArgs -Name 'project')
            $cfgName = [string](Get-Arg -ToolArgs $ToolArgs -Name 'configuration' -Default 'Release')
            $defaultOut = if ($action -eq 'pack') { 'artifacts/nupkg' } else { 'artifacts/publish' }
            $outDir = Resolve-AgentPath -Path ([string](Get-Arg -ToolArgs $ToolArgs -Name 'output' -Default $defaultOut)) -AllowMissing

            $a = [System.Collections.Generic.List[string]]::new()
            $a.Add($action); $a.Add($proj); $a.Add('-c'); $a.Add($cfgName); $a.Add('-o'); $a.Add($outDir); $a.Add('--nologo')
            if ($action -eq 'pack') {
                $a.Add('--include-symbols')
                $a.Add('-p:SymbolPackageFormat=snupkg')
            }
            else {
                $rid = Get-Arg -ToolArgs $ToolArgs -Name 'runtime'
                if ($rid) {
                    $a.Add('-r'); $a.Add([string]$rid)
                    $sc = [bool](Get-Arg -ToolArgs $ToolArgs -Name 'self_contained' -Default $false)
                    $a.Add('--self-contained'); $a.Add($(if ($sc) { 'true' } else { 'false' }))
                }
            }
            $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("dotnet $($a -join ' ')`nexit=$($r.exitCode)`n$($r.output)") }
        }
    }

    # ----------------------------------------------- enterprise PowerShell ----
    $reg['NewPsModule'] = @{
        Description = 'Scaffold an enterprise PowerShell script module or binary C# cmdlet module with Public/Private/Tests layout, .psd1 manifest, and Pester tests.'
        Parameters  = @{
            type = 'object'; required = @('name')
            properties = @{
                name        = @{ type = 'string'; description = 'Module name, e.g. Company.StorageTools.' }
                kind        = @{ type = 'string'; enum = @('script', 'binary'); description = 'script (.psm1) or binary (C# PSCmdlet .csproj). Default script.' }
                output_dir  = @{ type = 'string'; description = 'Base directory. Default ./src/<name>.' }
                author      = @{ type = 'string'; description = 'Module author. Default Gurulence.' }
                description = @{ type = 'string'; description = 'Module description.' }
                framework   = @{ type = 'string'; description = 'For binary modules: e.g. net8.0 or netstandard2.0. Default net8.0.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }
            $name = [string](Get-Arg -ToolArgs $ToolArgs -Name 'name')
            $kind = [string](Get-Arg -ToolArgs $ToolArgs -Name 'kind' -Default 'script')
            $outRel = [string](Get-Arg -ToolArgs $ToolArgs -Name 'output_dir' -Default (Join-Path -Path 'src' -ChildPath $name))
            $outFull = Resolve-AgentPath -Path $outRel -AllowMissing
            $author = [string](Get-Arg -ToolArgs $ToolArgs -Name 'author' -Default 'Gurulence')
            $desc = [string](Get-Arg -ToolArgs $ToolArgs -Name 'description' -Default "Enterprise PowerShell module $name")
            $fw = [string](Get-Arg -ToolArgs $ToolArgs -Name 'framework' -Default 'net8.0')

            $scaffolder = Join-Path -Path $script:KitDir -ChildPath 'tools/New-EnterprisePsModule.ps1'
            if (-not (Test-Path -LiteralPath $scaffolder)) {
                return [pscustomobject]@{ ok = $false; output = "ERROR: scaffolder script not found at $scaffolder" }
            }
            $a = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scaffolder, '-Name', $name, '-Kind', $kind, '-OutputPath', $outFull, '-Author', $author, '-Description', $desc, '-TargetFramework', $fw)
            $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList $a -WorkingDirectory $script:Workspace -TimeoutSec $script:CommandTimeout
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("exit=$($r.exitCode)`n$($r.output)") }
        }
    }

    $reg['TestPsManifest'] = @{
        Description = 'Validate a PowerShell module manifest (.psd1) with Test-ModuleManifest and verify clean Import-Module behavior.'
        Parameters  = @{
            type = 'object'; required = @('manifest_path')
            properties = @{
                manifest_path = @{ type = 'string'; description = 'Path to .psd1 manifest.' }
                import_check  = @{ type = 'boolean'; description = 'Also test Import-Module in an isolated pwsh process. Default true.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }
            $manifest = Resolve-AgentPath -Path (Get-Arg -ToolArgs $ToolArgs -Name 'manifest_path')
            $doImport = [bool](Get-Arg -ToolArgs $ToolArgs -Name 'import_check' -Default $true)
            $esc = $manifest -replace '''', ''''''
            $template = @'
$ErrorActionPreference = 'Stop'
$m = Test-ModuleManifest -Path '__MANIFEST__'
Write-Output ('MANIFEST OK: {0} v{1}' -f $m.Name, $m.Version)
'@
            if ($doImport) {
                $template += @'

Import-Module '__MANIFEST__' -Force -ErrorAction Stop
$cmds = @(Get-Command -Module $m.Name)
Write-Output ('IMPORT OK: exported {0} command(s): {1}' -f $cmds.Count, (($cmds.Name) -join ', '))
'@
            }
            $cmd = $template.Replace('__MANIFEST__', $esc)
            $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $script:Workspace -TimeoutSec 120
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = ("exit=$($r.exitCode)`n$($r.output)") }
        }
    }

    $reg['CodeSign'] = @{
        Description = 'Verify or apply Authenticode / NuGet code signatures. Never accepts plaintext passwords; uses OS certificate store or timestamp server.'
        Parameters  = @{
            type = 'object'; required = @('action', 'path')
            properties = @{
                action           = @{ type = 'string'; enum = @('verify-ps', 'sign-ps', 'verify-nuget', 'sign-nuget') }
                path             = @{ type = 'string'; description = 'File or .nupkg path.' }
                thumbprint       = @{ type = 'string'; description = 'Certificate thumbprint in CurrentUser/LocalMachine store (for sign-ps / sign-nuget).' }
                timestamp_server = @{ type = 'string'; description = 'RFC3161 timestamp server URL, e.g. http://timestamp.digicert.com' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $action = [string](Get-Arg -ToolArgs $ToolArgs -Name 'action')
            $target = Resolve-AgentPath -Path (Get-Arg -ToolArgs $ToolArgs -Name 'path')
            $thumb = [string](Get-Arg -ToolArgs $ToolArgs -Name 'thumbprint' -Default '')
            $ts = [string](Get-Arg -ToolArgs $ToolArgs -Name 'timestamp_server' -Default 'http://timestamp.digicert.com')

            if ($action -in @('verify-nuget', 'sign-nuget')) {
                $dotnet = Resolve-DotnetPath
                if ($action -eq 'verify-nuget') {
                    $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList @('nuget', 'verify', '--all', $target) -WorkingDirectory $script:Workspace -TimeoutSec 120
                    return [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = $r.output }
                }
                if (-not $thumb) { return [pscustomobject]@{ ok = $false; output = 'ERROR: thumbprint is required for sign-nuget.' } }
                $a = @('nuget', 'sign', $target, '--certificate-fingerprint', $thumb, '--timestamper', $ts)
                $r = Invoke-CapturedProcess -FilePath $dotnet -ArgumentList $a -WorkingDirectory $script:Workspace -TimeoutSec 120
                return [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = $r.output }
            }

            $pwsh = Resolve-PwshPath
            if (-not $pwsh) { return [pscustomobject]@{ ok = $false; output = 'ERROR: pwsh not found.' } }
            $signer = Join-Path -Path $script:KitDir -ChildPath 'tools/Sign-Artifact.ps1'
            $a = [System.Collections.Generic.List[string]]::new()
            $a.Add('-NoLogo'); $a.Add('-NoProfile'); $a.Add('-NonInteractive'); $a.Add('-File'); $a.Add($signer)
            $a.Add('-Path'); $a.Add($target)
            if ($action -eq 'verify-ps') {
                $a.Add('-VerifyOnly')
            }
            else {
                if (-not $thumb) { return [pscustomobject]@{ ok = $false; output = 'ERROR: thumbprint is required for sign-ps.' } }
                $a.Add('-Thumbprint'); $a.Add($thumb)
                $a.Add('-TimestampServer'); $a.Add($ts)
            }
            $r = Invoke-CapturedProcess -FilePath $pwsh -ArgumentList $a.ToArray() -WorkingDirectory $script:Workspace -TimeoutSec 120
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = $r.output }
        }
    }

    # ----------------------------------------------------------------- git ----
    $reg['GitInfo'] = @{
        Description = 'Read-only git inspection: status, diff, log, branch, show. Never mutates the repository.'
        Parameters  = @{
            type = 'object'; required = @('op')
            properties = @{
                op     = @{ type = 'string'; enum = @('status', 'diff', 'diff-staged', 'log', 'branch', 'show') }
                target = @{ type = 'string'; description = 'Pathspec or revision. Optional.' }
                count  = @{ type = 'integer'; description = 'For log: number of commits. Default 10.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $git = $script:Cfg.agent.gitPath
            $op = [string](Get-Arg -ToolArgs $ToolArgs -Name 'op')
            $tgt = Get-Arg -ToolArgs $ToolArgs -Name 'target'
            $cnt = [int](Get-Arg -ToolArgs $ToolArgs -Name 'count' -Default 10)
            $a = switch ($op) {
                'status' { @('status', '--short', '--branch') }
                'diff' {
                    $base = @('diff', '--stat', '--patch')
                    if ($tgt) { $base += [string]$tgt }
                    $base
                }
                'diff-staged' { @('diff', '--cached', '--stat', '--patch') }
                'log' { @('log', "--max-count=$cnt", '--pretty=format:%h %ad %s', '--date=short') }
                'branch' { @('branch', '--all', '-vv') }
                'show' { @('show', '--stat', '--patch', $(if ($tgt) { [string]$tgt } else { 'HEAD' })) }
                default { @('status') }
            }
            $r = Invoke-CapturedProcess -FilePath $git -ArgumentList $a -WorkingDirectory $script:Workspace -TimeoutSec 60
            [pscustomobject]@{ ok = ($r.exitCode -eq 0); output = $r.output }
        }
    }

    # ---------------------------------------------------------------- todo ----
    $reg['UpdateTodo'] = @{
        Description = 'Publish your plan/checklist to the human. Call this first for anything non-trivial, and again whenever a step completes. States: pending, in_progress, done.'
        Parameters  = @{
            type = 'object'; required = @('items')
            properties = @{
                items = @{
                    type  = 'array'
                    items = @{
                        type = 'object'; required = @('step', 'state')
                        properties = @{
                            step  = @{ type = 'string' }
                            state = @{ type = 'string'; enum = @('pending', 'in_progress', 'done') }
                        }
                    }
                }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $items = @(Get-Arg -ToolArgs $ToolArgs -Name 'items' -Default @())
            $icon = @{ done = '[x]'; in_progress = '[~]'; pending = '[ ]' }
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine('# Agent plan')
            [void]$sb.AppendLine("_updated $(Get-Date -Format 'u')_")
            [void]$sb.AppendLine('')
            foreach ($i in $items) {
                [void]$sb.AppendLine(('{0} {1}' -f $icon[[string]$i.state], $i.step))
            }
            $path = Join-Path -Path $script:Workspace -ChildPath $script:Cfg.agent.todoFile
            $dir = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllText($path, $sb.ToString())
            $done = @($items | Where-Object { $_.state -eq 'done' }).Count
            $lines = @($items | ForEach-Object { '{0} {1}' -f $icon[[string]$_.state], $_.step })
            [pscustomobject]@{ ok = $true; output = ("Plan updated ($done/$($items.Count) done).`n" + ($lines -join "`n")) }
        }
    }

    # --------------------------------------------------------- ask a human ----
    $reg['AskUser'] = @{
        Description = 'Ask the human a question and wait for the answer. Use when the task is genuinely ambiguous (target framework, naming, breaking-change policy). Do not use it to ask permission for tool calls - that is automatic.'
        Parameters  = @{
            type = 'object'; required = @('question')
            properties = @{
                question = @{ type = 'string' }
                options  = @{ type = 'array'; items = @{ type = 'string' }; description = 'Optional suggested answers.' }
            }
        }
        Script      = {
            param([hashtable]$ToolArgs)
            $q = [string](Get-Arg -ToolArgs $ToolArgs -Name 'question')
            $opts = @(Get-Arg -ToolArgs $ToolArgs -Name 'options' -Default @())
            Write-Host -Object ''
            Write-Host -Object '  AGENT ASKS: ' -ForegroundColor Magenta -NoNewline
            Write-Host -Object $q -ForegroundColor White
            if ($opts.Count) {
                for ($i = 0; $i -lt $opts.Count; $i++) {
                    Write-Host -Object "    $($i + 1)) $($opts[$i])" -ForegroundColor DarkGray
                }
            }
            $answer = Read-Host -Prompt '  your answer'
            [pscustomobject]@{ ok = $true; output = "USER ANSWER: $answer" }
        }
    }

    return $reg
}
