<#
.SYNOPSIS
  taskviz - see what is registered in Windows Task Scheduler, on a local web page.

.DESCRIPTION
  Starts a small web server on 127.0.0.1 (this PC only) and opens it in the browser.
  The page reads every scheduled task live and can run / stop / enable / disable them.
  Press Ctrl+C (or close the window, or use the page's stop button) to quit.

.EXAMPLE
  .\taskviz.ps1                        # serve on http://127.0.0.1:31415/
  .\taskviz.ps1 -Port 9000 -NoOpen
  .\taskviz.ps1 -Export snapshot.html  # write a self-contained snapshot instead of serving
#>
param(
    [int]$Port = 31415,
    [switch]$NoOpen,
    [string]$Export,
    [int]$HistoryDays = 3
)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding $false
$appHtml = Join-Path $PSScriptRoot 'app.html'

function Format-Local($dt) {
    # COM reports "never" as placeholder dates in 1899/1999
    if ($null -eq $dt -or $dt.Year -lt 2000) { return $null }
    $dt.ToString('yyyy-MM-ddTHH:mm:ss', $inv)
}

function Get-Safe([scriptblock]$sb) { try { & $sb } catch { $null } }

function ConvertTo-JsonText($obj) { (ConvertTo-Json $obj -Depth 6 -Compress).Replace('</', '<\/') }

# --- data --------------------------------------------------------------------

function Get-TaskvizData {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $tasks = New-Object System.Collections.Generic.List[object]

    function Add-Folder($folder) {
        foreach ($t in @(Get-Safe { $folder.GetTasks(1) })) {   # 1 = TASK_ENUM_HIDDEN
            if ($null -eq $t) { continue }
            $result = Get-Safe { [int64]$t.LastTaskResult }
            if ($null -ne $result -and $result -lt 0) { $result += 4294967296 }
            $tasks.Add([ordered]@{
                path       = $t.Path
                name       = $t.Name
                folder     = $folder.Path
                state      = Get-Safe { [int]$t.State }
                enabled    = Get-Safe { [bool]$t.Enabled }
                lastRun    = Format-Local (Get-Safe { $t.LastRunTime })
                lastResult = $result
                nextRun    = Format-Local (Get-Safe { $t.NextRunTime })
                missedRuns = Get-Safe { [int]$t.NumberOfMissedRuns }
                xml        = Get-Safe { $t.Xml }
            })
        }
        foreach ($sub in @(Get-Safe { $folder.GetFolders(0) })) {
            if ($null -ne $sub) { Add-Folder $sub }
        }
    }
    Add-Folder ($svc.GetFolder('\'))

    # run history: Microsoft-Windows-TaskScheduler/Operational, disabled by default on Windows
    $history = [ordered]@{ enabled = $false; days = $HistoryDays; note = $null; runs = @{} }
    try {
        $logName = 'Microsoft-Windows-TaskScheduler/Operational'
        $log = Get-WinEvent -ListLog $logName
        $history.enabled = [bool]$log.IsEnabled
        if ($log.IsEnabled) {
            # 100 started, 102 completed, 201 action completed (exit code), 101/103 failed to start
            $filter = @{ LogName = $logName; Id = 100, 101, 102, 103, 201; StartTime = (Get-Date).AddDays(-$HistoryDays) }
            $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)
            $byInstance = @{}
            foreach ($e in $events) {
                $d = @{}
                foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
                $key = if ($d.InstanceId) { $d.InstanceId } elseif ($d.TaskInstanceId) { $d.TaskInstanceId } else { "rec$($e.RecordId)" }
                $run = $byInstance[$key]
                if (-not $run) {
                    $run = [ordered]@{ task = $null; s = $null; e = $null; r = $null; f = $false }
                    $byInstance[$key] = $run
                }
                if (-not $run.task) { $run.task = $d.TaskName }
                $at = Format-Local $e.TimeCreated
                switch ($e.Id) {
                    100 { $run.s = $at }
                    102 { $run.e = $at }
                    201 { if ($d.ResultCode) { $run.r = [int64]$d.ResultCode } }
                    default {
                        if (-not $run.s) { $run.s = $at }
                        $run.f = $true
                        if ($d.ResultCode) { $run.r = [int64]$d.ResultCode }
                    }
                }
            }
            $runs = @{}
            foreach ($run in $byInstance.Values) {
                if (-not $run.task -or -not ($run.s -or $run.e)) { continue }
                if (-not $runs.ContainsKey($run.task)) { $runs[$run.task] = New-Object System.Collections.Generic.List[object] }
                $runs[$run.task].Add([ordered]@{ s = $run.s; e = $run.e; r = $run.r; f = $run.f })
            }
            $history.runs = $runs
        }
    } catch {
        $history.note = $_.Exception.Message
    }

    , [ordered]@{
        generatedAt = Format-Local (Get-Date)
        computer    = $env:COMPUTERNAME
        user        = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        userProfile = $env:USERPROFILE
        history     = $history
        tasks       = $tasks
    }
}

function Get-PageHtml($config, [string]$dataJson) {
    $tpl = [IO.File]::ReadAllText($appHtml, [Text.Encoding]::UTF8)
    $tpl.Replace('__TASKVIZ_CONFIG__', (ConvertTo-JsonText $config)).Replace('__TASKVIZ_DATA__', $dataJson)
}

function Invoke-TaskAction([string]$action, [string]$path) {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $i = $path.LastIndexOf('\')
    $folder = if ($i -le 0) { '\' } else { $path.Substring(0, $i) }
    $task = $svc.GetFolder($folder).GetTask($path.Substring($i + 1))
    switch ($action) {
        'run'     { [void]$task.Run($null) }
        'stop'    { $task.Stop(0) }
        'enable'  { $task.Enabled = $true }
        'disable' { $task.Enabled = $false }
        default   { throw "unknown action: $action" }
    }
}

# --- snapshot mode -----------------------------------------------------------

if ($Export) {
    $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Export)
    $html = Get-PageHtml @{ mode = 'static' } (ConvertTo-JsonText (Get-TaskvizData))
    [IO.File]::WriteAllText($out, $html, $utf8)
    Write-Host "snapshot -> $out"
    if (-not $NoOpen) { Start-Process $out }
    return
}

# --- server mode -------------------------------------------------------------
# A plain TcpListener bound to 127.0.0.1, so the port is unreachable from other machines.
# (HttpListener/http.sys would listen on 0.0.0.0 and route by the spoofable Host header.)

$inUse = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object { $_.Port })
$listener = $null
foreach ($p in $Port..($Port + 50)) {
    if ($inUse -contains $p) { continue }
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
    $l.ExclusiveAddressUse = $true
    try { $l.Start(); $listener = $l; $Port = $p; break } catch { }
}
if (-not $listener) { throw "No free port in $Port..$($Port + 50). Pick another one with -Port." }

# Mutating requests must carry this token. It is only embedded in the page served from
# this origin, so other sites cannot read it (and the custom header forces a CORS preflight we never allow).
$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$token = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
$allowedHosts = "127.0.0.1:$Port", "localhost:$Port"
$stop = $false

$reasons = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }

function Send($req, [int]$status, [string]$type, [string]$body) {
    $buf = $utf8.GetBytes($body)
    $head = "HTTP/1.1 $status $($reasons[$status])`r`n" +
            "Content-Type: $type; charset=utf-8`r`n" +
            "Content-Length: $($buf.Length)`r`n" +
            "Cache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $req.stream.Write($hb, 0, $hb.Length)
    $req.stream.Write($buf, 0, $buf.Length)
}

function Send-Json($req, [int]$status, $obj) { Send $req $status 'application/json' (ConvertTo-JsonText $obj) }

function Read-Request($client) {
    $stream = $client.GetStream()
    $stream.ReadTimeout = 5000
    # headers: read until CRLFCRLF
    $head = New-Object IO.MemoryStream
    $crlf = [byte[]](13, 10, 13, 10)
    $matched = 0
    while ($matched -lt 4) {
        $b = $stream.ReadByte()
        if ($b -lt 0 -or $head.Length -gt 32KB) { return $null }
        $head.WriteByte($b)
        $matched = if ($b -eq $crlf[$matched]) { $matched + 1 } elseif ($b -eq 13) { 1 } else { 0 }
    }
    $lines = [Text.Encoding]::ASCII.GetString($head.ToArray()) -split "`r`n"
    $first = $lines[0] -split ' '
    if ($first.Count -lt 3) { return $null }
    $headers = @{}   # case-insensitive
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        $i = $line.IndexOf(':')
        if ($i -gt 0) { $headers[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
    }
    $body = ''
    $len = 0
    if ([int]::TryParse([string]$headers['Content-Length'], [ref]$len) -and $len -gt 0) {
        if ($len -gt 1MB) { return $null }
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) {
            $n = $stream.Read($buf, $read, $len - $read)
            if ($n -le 0) { return $null }
            $read += $n
        }
        $body = $utf8.GetString($buf)
    }
    @{ stream = $stream; method = $first[0]; path = ($first[1] -split '\?')[0]; headers = $headers; body = $body }
}

function Invoke-Request($req) {
    if ($allowedHosts -notcontains $req.headers['Host']) { Send $req 403 'text/plain' 'forbidden'; return }
    if ($req.method -eq 'POST' -and $req.headers['X-Taskviz-Token'] -ne $token) { Send-Json $req 403 @{ error = 'invalid token' }; return }

    switch ("$($req.method) $($req.path)") {
        'GET /' {
            Send $req 200 'text/html' (Get-PageHtml @{ mode = 'live'; token = $token } 'null')
        }
        'GET /api/data' {
            Send $req 200 'application/json' (ConvertTo-JsonText (Get-TaskvizData))
        }
        'POST /api/action' {
            try {
                $body = $req.body | ConvertFrom-Json
                Invoke-TaskAction $body.action $body.path
                Write-Host ("{0:HH:mm:ss} {1} {2}" -f (Get-Date), $body.action, $body.path)
                Send-Json $req 200 @{ ok = $true }
            } catch {
                Send-Json $req 500 @{ error = $_.Exception.Message }
            }
        }
        'POST /api/shutdown' {
            Send-Json $req 200 @{ ok = $true }
            $script:stop = $true
        }
        default { Send $req 404 'text/plain' 'not found' }
    }
}

function Complete-Client($client) {
    try {
        if (-not [Net.IPAddress]::IsLoopback($client.Client.RemoteEndPoint.Address)) { return }
        $req = Read-Request $client
        if (-not $req) { return }
        try { Invoke-Request $req }
        catch { try { Send $req 500 'text/plain' $_.Exception.Message } catch { } }
    } catch {
        # client went away mid-request
    } finally {
        $client.Close()
    }
}

$url = "http://127.0.0.1:$Port/"
Write-Host "taskviz is running at $url"
Write-Host 'Press Ctrl+C or close this window to stop.'
if (-not $NoOpen) { Start-Process $url }

# Single-threaded loop. Browsers open speculative connections that may never send a request,
# so only serve sockets that have data and drop idle ones, instead of blocking on each accept.
$clients = New-Object System.Collections.Generic.List[object]
try {
    while (-not $stop) {
        while ($listener.Pending()) {
            $clients.Add(@{ client = $listener.AcceptTcpClient(); since = [DateTime]::UtcNow })
        }
        $busy = $false
        foreach ($c in $clients.ToArray()) {
            if ($c.client.Available -gt 0) {
                $busy = $true
                [void]$clients.Remove($c)
                Complete-Client $c.client
            } elseif (([DateTime]::UtcNow - $c.since).TotalSeconds -gt 15) {
                [void]$clients.Remove($c)
                $c.client.Close()
            }
        }
        if (-not $busy) { Start-Sleep -Milliseconds 40 }
    }
} finally {
    foreach ($c in $clients) { $c.client.Close() }
    $listener.Stop()
    Write-Host 'taskviz stopped.'
}
