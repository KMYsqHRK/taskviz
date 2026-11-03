<#
.SYNOPSIS
  Regenerates docs/screenshots/*.png from the fictional demo data, using headless Microsoft Edge.
  Your real task list is never used.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) "taskviz-shots-$PID"
$outDir = Join-Path $root 'docs\screenshots'
[void](New-Item -ItemType Directory -Force -Path $work, $outDir)

$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found.' }

& (Join-Path $PSScriptRoot 'New-DemoData.ps1') -Out (Join-Path $work 'demo.json')
& (Join-Path $root 'taskviz.ps1') -Export (Join-Path $work 'demo.html') -DataFile (Join-Path $work 'demo.json') -NoOpen

$page = ([Uri](Join-Path $work 'demo.html')).AbsoluteUri
$shots = @(
    @{ name = 'overview.png'; hash = 'range=day&cats=mine,app,windows'; size = '1280,1640'; dark = $false }
    @{ name = 'week.png';     hash = 'range=week&cats=mine';            size = '1280,1100'; dark = $false }
    @{ name = 'detail.png';   hash = 'cats=mine,app,windows&q=EdgeUpdateCore&noscroll&open=' + [Uri]::EscapeDataString('\MicrosoftEdgeUpdateCore'); size = '1280,1500'; dark = $false }
    @{ name = 'overview-dark.png'; hash = 'range=day&cats=mine,app,windows'; size = '1280,1640'; dark = $true }
)
foreach ($s in $shots) {
    $out = Join-Path $outDir $s.name
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
        "--user-data-dir=$work\profile", "--window-size=$($s.size)", '--virtual-time-budget=3000', "--screenshot=$out")
    if ($s.dark) { $edgeArgs += '--force-dark-mode', '--blink-settings=preferredColorScheme=0' }
    $edgeArgs += "$page#$($s.hash)"
    Start-Process -FilePath $edge -ArgumentList $edgeArgs -Wait -WindowStyle Hidden
    Write-Host "screenshot -> $out"
}
Remove-Item -Recurse -Force $work
