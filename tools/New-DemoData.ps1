<#
.SYNOPSIS
  Writes a fictional task list (same shape as taskviz's /api/data) for screenshots and tests.
  Times are relative to now, so the timeline always has something to show.

.EXAMPLE
  .\tools\New-DemoData.ps1 -Out demo.json
  .\taskviz.ps1 -Export demo.html -DataFile demo.json
#>
param([Parameter(Mandatory = $true)][string]$Out)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding $false
$now = Get-Date
$today = $now.Date
$userSid = 'S-1-5-21-1000-1000-1000-1001'

function Format-Local($dt) { if ($dt) { $dt.ToString('yyyy-MM-ddTHH:mm:ss', $inv) } }

function Get-Fingerprint([string]$text) {
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($text))
    -join ($hash[0..7] | ForEach-Object { $_.ToString('x2') })
}

function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

function New-TaskXml {
    param(
        [string]$Triggers, [string]$Command, [string]$Arguments, [string]$WorkDir, [string]$Description,
        [switch]$Hidden, [string]$UserId = $userSid, [string]$Multiple = 'IgnoreNew', [string]$TimeLimit = 'PT1H'
    )
    $desc = if ($Description) { "<Description>$(ConvertTo-XmlText $Description)</Description>" }
    $argsXml = if ($Arguments) { "<Arguments>$(ConvertTo-XmlText $Arguments)</Arguments>" }
    $wd = if ($WorkDir) { "<WorkingDirectory>$(ConvertTo-XmlText $WorkDir)</WorkingDirectory>" }
    $hid = if ($Hidden) { '<Hidden>true</Hidden>' }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>$desc</RegistrationInfo>
  <Principals><Principal id="Author"><UserId>$UserId</UserId><LogonType>InteractiveToken</LogonType></Principal></Principals>
  <Settings><MultipleInstancesPolicy>$Multiple</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StartWhenAvailable>true</StartWhenAvailable>$hid<ExecutionTimeLimit>$TimeLimit</ExecutionTimeLimit></Settings>
  <Triggers>$Triggers</Triggers>
  <Actions Context="Author"><Exec><Command>$(ConvertTo-XmlText $Command)</Command>$argsXml$wd</Exec></Actions>
</Task>
"@
}

# --- trigger helpers ---
function Daily($at) { "<CalendarTrigger><StartBoundary>$(Format-Local $at)</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>" }
function Weekly($at, [string]$day) { "<CalendarTrigger><StartBoundary>$(Format-Local $at)</StartBoundary><ScheduleByWeek><WeeksInterval>1</WeeksInterval><DaysOfWeek><$day /></DaysOfWeek></ScheduleByWeek></CalendarTrigger>" }
function Monthly($at, [int]$day) { "<CalendarTrigger><StartBoundary>$(Format-Local $at)</StartBoundary><ScheduleByMonth><DaysOfMonth><Day>$day</Day></DaysOfMonth><Months><January /><February /><March /><April /><May /><June /><July /><August /><September /><October /><November /><December /></Months></ScheduleByMonth></CalendarTrigger>" }
function Every($start, [int]$minutes) { "<TimeTrigger><StartBoundary>$(Format-Local $start)</StartBoundary><Repetition><Interval>PT$($minutes)M</Interval></Repetition></TimeTrigger>" }
function Logon { '<LogonTrigger><Enabled>true</Enabled></LogonTrigger>' }

# --- next/previous occurrence helpers ---
function Get-NextEvery($start, [int]$minutes) { $start.AddMinutes([math]::Ceiling(($now - $start).TotalMinutes / $minutes) * $minutes) }
function Get-NextDaily([int]$hour) { $t = $today.AddHours($hour); if ($t -le $now) { $t.AddDays(1) } else { $t } }
function Get-NextWeekday([DayOfWeek]$dow, [int]$hour) {
    $t = $today.AddDays((7 + [int]$dow - [int]$today.DayOfWeek) % 7).AddHours($hour)
    if ($t -le $now) { $t.AddDays(7) } else { $t }
}

$tasks = New-Object System.Collections.Generic.List[object]
function Add-Task {
    param([string]$Path, [string]$Xml, [int]$State = 3, [bool]$Enabled = $true, $LastRun, [int64]$LastResult = 0, $NextRun)
    $i = $Path.LastIndexOf('\')
    $tasks.Add([ordered]@{
        path = $Path; name = $Path.Substring($i + 1); folder = $(if ($i -le 0) { '\' } else { $Path.Substring(0, $i) })
        state = $State; enabled = $Enabled
        lastRun = Format-Local $LastRun; lastResult = $LastResult; nextRun = Format-Local $NextRun
        missedRuns = 0; xml = $Xml; hash = Get-Fingerprint $Xml
    })
}

# --- your own tasks ---
Add-Task '\Backup Photos' (New-TaskXml -Triggers (Daily $today.AddDays(-60).AddHours(2)) `
        -Command 'powershell.exe' -Arguments '-NoProfile -File "C:\Users\demo\scripts\backup-photos.ps1"' `
        -Description 'Mirror ~/Pictures to the NAS every night.') `
    -LastRun $today.AddHours(2) -NextRun (Get-NextDaily 2)

$apiStart = $today.AddDays(-3).AddHours(8)
Add-Task '\Dev\api-server' (New-TaskXml -Triggers ((Logon) + (Every $apiStart 5)) -TimeLimit 'PT0S' `
        -Command 'C:\Users\demo\dev\api\run-server.cmd' -WorkDir 'C:\Users\demo\dev\api' `
        -Description 'Keeps the local API server running. Re-launched every 5 minutes if it died.') `
    -State 4 -LastRun (Get-NextEvery $apiStart 5).AddMinutes(-5) -LastResult 0x800710E0 -NextRun (Get-NextEvery $apiStart 5)

$syncStart = $today.AddDays(-20).AddMinutes(7)
$syncNext = Get-NextEvery $syncStart 15
Add-Task '\Dev\notes-sync' (New-TaskXml -Triggers (Every $syncStart 15) `
        -Command 'C:\Users\demo\AppData\Local\Programs\Python\Python312\pythonw.exe' -Arguments '-m notesync push' `
        -WorkDir 'C:\Users\demo\notes' -Description 'Push notes to the git remote.') `
    -LastRun $syncNext.AddMinutes(-15) -NextRun $syncNext

$lastMonday = (Get-NextWeekday Monday 9).AddDays(-7)
Add-Task '\Weekly report' (New-TaskXml -Triggers (Weekly $today.AddDays(-90).AddHours(9) 'Monday') `
        -Command 'C:\Users\demo\AppData\Local\Programs\Python\Python312\python.exe' -Arguments 'C:\Users\demo\scripts\weekly_report.py' `
        -Description 'Summarise last week and mail it to myself.') `
    -LastRun $lastMonday -LastResult 1 -NextRun (Get-NextWeekday Monday 9)

Add-Task '\Cleanup Downloads' (New-TaskXml -Triggers (Monthly $today.AddDays(-200).AddHours(3) 1) `
        -Command 'powershell.exe' -Arguments '-NoProfile -File "C:\Users\demo\scripts\cleanup-downloads.ps1"') `
    -State 1 -Enabled $false -LastRun (Get-Date -Year $today.Year -Month $today.Month -Day 1).Date.AddHours(3)

# --- a planted persistence task, the kind the security check is for (payload is a harmless echo) ---
$payload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Write-Output 'taskviz demo'"))
$evilStart = $today.AddDays(-1).AddHours(10).AddMinutes(13)
Add-Task '\MicrosoftEdgeUpdateCore' (New-TaskXml -Triggers ((Logon) + (Every $evilStart 30)) -Hidden `
        -Command 'powershell.exe' -Arguments "-w hidden -nop -ep bypass -enc $payload") `
    -LastRun (Get-NextEvery $evilStart 30).AddMinutes(-30) -NextRun (Get-NextEvery $evilStart 30)

# --- apps ---
$gStart = $today.AddDays(-10).AddMinutes(41)
Add-Task '\GoogleUpdaterTaskUser' (New-TaskXml -Triggers (Every $gStart 60) `
        -Command 'C:\Users\demo\AppData\Local\Google\GoogleUpdater\updater.exe' -Arguments '--wake') `
    -LastRun (Get-NextEvery $gStart 60).AddHours(-1) -NextRun (Get-NextEvery $gStart 60)

Add-Task '\Adobe Acrobat Update Task' (New-TaskXml -Triggers ((Logon) + (Daily $today.AddDays(-300).AddHours(10))) `
        -Command 'C:\Program Files (x86)\Common Files\Adobe\ARM\1.0\AdobeARM.exe') `
    -LastRun $today.AddHours(10).AddDays($(if ($now.Hour -ge 10) { 0 } else { -1 })) -NextRun (Get-NextDaily 10)

# --- Windows ---
Add-Task '\Microsoft\Windows\Defrag\ScheduledDefrag' (New-TaskXml -UserId 'S-1-5-18' `
        -Triggers (Weekly $today.AddDays(-400).AddHours(1) 'Wednesday') `
        -Command '%windir%\system32\defrag.exe' -Arguments '-c -h -o -$') `
    -LastRun (Get-NextWeekday Wednesday 1).AddDays(-7) -NextRun (Get-NextWeekday Wednesday 1)

Add-Task '\Microsoft\Windows\WindowsUpdate\Scheduled Start' (New-TaskXml -UserId 'S-1-5-18' `
        -Triggers (Daily $today.AddDays(-400).AddHours(4)) `
        -Command 'C:\Windows\system32\sc.exe' -Arguments 'start wuauserv') `
    -LastRun $today.AddHours(4).AddDays($(if ($now.Hour -ge 4) { 0 } else { -1 })) -NextRun (Get-NextDaily 4)

# --- run history for one task, with a single failure ---
$runs = New-Object System.Collections.Generic.List[object]
for ($k = 1; $k -le 96; $k++) {
    $s = $syncNext.AddMinutes(-15 * $k)
    $runs.Add([ordered]@{ s = Format-Local $s; e = Format-Local $s.AddSeconds(4); r = $(if ($k -eq 9) { 2 } else { 0 }); f = $false })
}

# baseline taken two days ago: everything except the planted task
$baseline = [ordered]@{}
foreach ($t in $tasks) { if ($t.path -ne '\MicrosoftEdgeUpdateCore') { $baseline[$t.path] = $t.hash } }

$data = [ordered]@{
    generatedAt = Format-Local $now
    computer    = 'DEMO-PC'
    user        = 'DEMO-PC\demo'
    userProfile = 'C:\Users\demo'
    history     = [ordered]@{ enabled = $true; days = 3; note = $null; runs = @{ '\Dev\notes-sync' = $runs } }
    baseline    = [ordered]@{ savedAt = Format-Local $today.AddDays(-2).AddHours(18); tasks = $baseline }
    tasks       = $tasks
}
$path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
[IO.File]::WriteAllText($path, (ConvertTo-Json $data -Depth 8), $utf8)
Write-Host "demo data -> $path"
