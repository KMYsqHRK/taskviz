<#
.SYNOPSIS
  Smoke tests for taskviz. Runs on Windows PowerShell 5.1 and PowerShell 7.
  Read-only against the real Task Scheduler: no task is run, changed or created.

.EXAMPLE
  .\tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$taskviz = Join-Path $root 'taskviz.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "taskviz-test-$PID"
[void](New-Item -ItemType Directory -Force -Path $work)
$psExe = (Get-Process -Id $PID).Path   # children run on the same PowerShell edition as the tests
$utf8 = New-Object Text.UTF8Encoding $false
$failed = 0

Write-Host "taskviz tests on PowerShell $($PSVersionTable.PSVersion) ($([Environment]::OSVersion.VersionString))"

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok    $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

function Invoke-TaskvizScript([string[]]$Arguments) {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $taskviz @Arguments | Out-Host
    if ($LASTEXITCODE) { throw "taskviz.ps1 exited with $LASTEXITCODE" }
}

function Get-EmbeddedData([string]$HtmlPath) {
    $html = [IO.File]::ReadAllText($HtmlPath, $utf8)
    $m = [regex]::Match($html, '<script id="data" type="application/json">(.*?)</script>', 'Singleline')
    Assert-True $m.Success 'data block not found'
    $m.Groups[1].Value.Replace('<\/', '</') | ConvertFrom-Json
}

$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Get-RenderedDom([string]$HtmlPath, [string]$Hash) {
    $out = Join-Path $work "dom-$([guid]::NewGuid()).html"
    $url = ([Uri]$HtmlPath).AbsoluteUri + '#' + $Hash
    $edgeArgs = '--headless=new', '--disable-gpu', "--user-data-dir=$work\edge", '--virtual-time-budget=3000', '--dump-dom', $url
    Start-Process -FilePath $edge -ArgumentList $edgeArgs -Wait -WindowStyle Hidden -RedirectStandardOutput $out
    [IO.File]::ReadAllText($out, $utf8)
}

# --- page script -------------------------------------------------------------

Test-Case 'app.html script is valid JavaScript' {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { Write-Host '        (node not found, skipped)'; return }
    $html = [IO.File]::ReadAllText((Join-Path $root 'app.html'), $utf8)
    $m = [regex]::Match($html, "<script>\s*('use strict';.*?)</script>", 'Singleline')
    Assert-True $m.Success 'main script not found'
    $js = Join-Path $work 'app.js'
    [IO.File]::WriteAllText($js, $m.Groups[1].Value, $utf8)
    & $node.Source --check $js
    Assert-True ($LASTEXITCODE -eq 0) 'node --check failed'
}

# --- snapshot mode -----------------------------------------------------------

Test-Case 'exports a snapshot of the real task list' {
    $out = Join-Path $work 'real.html'
    Invoke-TaskvizScript @('-Export', $out, '-NoOpen', '-BaselineFile', (Join-Path $work 'none.json'))
    $data = Get-EmbeddedData $out
    Assert-True (@($data.tasks).Count -gt 0) 'no tasks collected'
    Assert-True (@($data.tasks | Where-Object { -not $_.hash -and $_.xml }).Count -eq 0) 'some tasks have XML but no fingerprint'
    Assert-True ([IO.File]::ReadAllText($out, $utf8) -match '"mode":"static"') 'snapshot is not in static mode'
}

$demoHtml = Join-Path $work 'demo.html'
Test-Case 'renders the demo data' {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\New-DemoData.ps1') -Out (Join-Path $work 'demo.json') | Out-Host
    Invoke-TaskvizScript @('-Export', $demoHtml, '-DataFile', (Join-Path $work 'demo.json'), '-NoOpen')
    Assert-True (@((Get-EmbeddedData $demoHtml).tasks).Count -eq 10) 'demo should have 10 tasks'
}

# Headless Edge sometimes prints nothing when launched from PowerShell 7; the page itself does not
# depend on the PowerShell edition, so CI requires rendering only where TASKVIZ_REQUIRE_RENDER is set.
$dom = if ($edge) { Get-RenderedDom $demoHtml 'cats=mine,app,windows&range=day' }
if (-not $dom -and $env:TASKVIZ_REQUIRE_RENDER) {
    Test-Case 'headless Edge renders the page' { throw "no DOM from Edge ($edge)" }
} elseif ($dom) {
    Test-Case 'page renders every demo task in the timeline' {
        $rows = [regex]::Matches($dom, 'class="tl-row(?: disabled)?" data-path="\\').Count
        Assert-True ($rows -eq 10) "expected 10 timeline rows, got $rows"
        Assert-True ($dom -match '<div id="stale"></div>') 'page shows an error banner'
    }
    Test-Case 'security check flags the planted task and only it' {
        $sec = [regex]::Match($dom, '<ul class="alerts" id="secAlerts">(.*?)</ul>', 'Singleline').Groups[1].Value
        Assert-True ($sec -match 'MicrosoftEdgeUpdateCore') 'planted task not reported'
        Assert-True ($sec -match 'PowerShell') 'encoded PowerShell not detected'
        $flagged = [regex]::Matches($sec, 'data-path="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        Assert-True (@($flagged).Count -eq 1) "unexpected tasks flagged: $($flagged -join ', ')"
    }
    Test-Case 'snapshot hides live-only controls' {
        Assert-True ($dom -match 'id="live" hidden') 'refresh/stop controls visible in a snapshot'
    }
} else {
    Write-Host '  skip  rendering tests (headless Edge unavailable or produced no output)' -ForegroundColor Yellow
}

# --- server mode -------------------------------------------------------------

$log = Join-Path $work 'server.log'
$baselineFile = Join-Path $work 'baseline.json'
$port = $null

function Read-SharedText([string]$Path) {
    # the server still holds the log open for writing
    $fs = New-Object IO.FileStream($Path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Close() }
}

function Invoke-Raw([string]$Method, [string]$Path, [hashtable]$Headers = @{}, [string]$Body = '') {
    $client = New-Object Net.Sockets.TcpClient('127.0.0.1', $port)
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 30000
        $bytes = $utf8.GetBytes($Body)
        $all = @{ 'Host' = "127.0.0.1:$port"; 'Content-Length' = $bytes.Length }
        foreach ($k in $Headers.Keys) { $all[$k] = $Headers[$k] }
        $head = "$Method $Path HTTP/1.1`r`n" + (($all.Keys | ForEach-Object { "${_}: $($all[$_])" }) -join "`r`n") + "`r`n`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $text = (New-Object IO.StreamReader($stream, $utf8)).ReadToEnd()
        $i = $text.IndexOf("`r`n`r`n")
        @{ status = [int]($text.Substring(9, 3)); body = $text.Substring($i + 4) }
    } finally {
        $client.Close()
    }
}

$server = Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$taskviz`"", '-NoOpen', '-Port', '31500', '-BaselineFile', "`"$baselineFile`"")
try {
    for ($i = 0; $i -lt 60 -and -not $port -and -not $server.HasExited; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $log) {
            $m = [regex]::Match((Read-SharedText $log), 'http://127\.0\.0\.1:(\d+)/')
            if ($m.Success) { $port = [int]$m.Groups[1].Value }
        }
    }
    Test-Case 'server starts and reports its URL' { Assert-True $port 'server did not start' }
    if (-not $port) { Write-Host (Read-SharedText $log); throw 'server did not start' }

    Test-Case 'listens on the loopback address only' {
        $listen = @(Get-NetTCPConnection -State Listen -OwningProcess $server.Id -ErrorAction SilentlyContinue)
        Assert-True ($listen.Count -gt 0) 'no listening socket found'
        Assert-True (@($listen | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count -eq 0) "listening on $($listen.LocalAddress -join ', ')"
        $lan = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        if ($lan) {
            $reached = $false
            try { $c = New-Object Net.Sockets.TcpClient($lan.IPAddress, $port); $c.Close(); $reached = $true } catch { }
            Assert-True (-not $reached) "reachable via $($lan.IPAddress)"
        }
    }

    $token = $null
    Test-Case 'serves the page with a token' {
        $r = Invoke-Raw 'GET' '/'
        Assert-True ($r.status -eq 200) "status $($r.status)"
        $m = [regex]::Match($r.body, '"token":"(\w+)"')
        Assert-True $m.Success 'token missing'
        $script:token = $m.Groups[1].Value
    }

    Test-Case 'serves live task data' {
        $r = Invoke-Raw 'GET' '/api/data'
        Assert-True ($r.status -eq 200) "status $($r.status)"
        Assert-True (@(($r.body | ConvertFrom-Json).tasks).Count -gt 0) 'no tasks'
    }

    Test-Case 'rejects a foreign Host header (DNS rebinding)' {
        Assert-True ((Invoke-Raw 'GET' '/api/data' @{ Host = "evil.example:$port" }).status -eq 403) 'not rejected'
    }

    Test-Case 'rejects actions without a valid token' {
        $body = '{"action":"run","path":"\\taskviz-test-missing"}'
        Assert-True ((Invoke-Raw 'POST' '/api/action' @{} $body).status -eq 403) 'missing token accepted'
        Assert-True ((Invoke-Raw 'POST' '/api/action' @{ 'X-Taskviz-Token' = 'wrong' } $body).status -eq 403) 'wrong token accepted'
    }

    Test-Case 'reports errors for unknown tasks and actions' {
        $r = Invoke-Raw 'POST' '/api/action' @{ 'X-Taskviz-Token' = $token } '{"action":"run","path":"\\taskviz-test-missing"}'
        Assert-True ($r.status -eq 500 -and ($r.body | ConvertFrom-Json).error) "status $($r.status)"
        $r = Invoke-Raw 'POST' '/api/action' @{ 'X-Taskviz-Token' = $token } '{"action":"delete","path":"\\taskviz-test-missing"}'
        Assert-True ($r.status -eq 500) 'unknown action accepted'
    }

    Test-Case 'does not stall on idle connections' {
        $idle = New-Object Net.Sockets.TcpClient('127.0.0.1', $port)
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-Raw 'GET' '/'
            Assert-True ($r.status -eq 200 -and $sw.ElapsedMilliseconds -lt 3000) "took $($sw.ElapsedMilliseconds) ms"
        } finally { $idle.Close() }
    }

    Test-Case 'saves a baseline and reports it back' {
        Assert-True ((Invoke-Raw 'POST' '/api/baseline' @{ 'X-Taskviz-Token' = $token }).status -eq 200) 'save failed'
        Assert-True (Test-Path $baselineFile) 'baseline file not written'
        $data = (Invoke-Raw 'GET' '/api/data').body | ConvertFrom-Json
        Assert-True ($data.baseline.savedAt) 'baseline not returned'
    }

    Test-Case 'stops on request' {
        Assert-True ((Invoke-Raw 'POST' '/api/shutdown' @{ 'X-Taskviz-Token' = $token }).status -eq 200) 'shutdown rejected'
        Assert-True ($server.WaitForExit(10000)) 'server still running'
    }
} finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "$failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all tests passed' -ForegroundColor Green
