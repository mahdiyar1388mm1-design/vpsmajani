# Writes a friendly STATUS.txt on the desktop so the user can see, inside the
# RDP session, whether persistence is working and when the session changes.
#
# Exit code is always 0.

param(
    [int]$SessionNumber = 0,
    [string]$TailscaleIP = '',
    [string]$StorageUrl = $env:STORAGE_URL,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\sync-common.ps1"

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

$mode = Get-SyncMode
Initialize-SyncWorkDir
$state = Join-Path $work 'state'

$desktop = 'C:\Users\NvDAdmin\Desktop'
New-Item -ItemType Directory -Force -Path $desktop | Out-Null

$statusFile = Join-Path $state 'status.txt'
$status = if (Test-Path $statusFile) { Get-Content $statusFile -Raw } else { 'Unknown.' }

$meta = $null
if ($mode -eq 'http' -and $StorageUrl) {
    try {
        $h = @{}
        if ($env:SYNC_TOKEN) { $h['Authorization'] = "Bearer $env:SYNC_TOKEN" }
        $meta = Invoke-RestMethod -Method Get -Uri "$StorageUrl/meta" -Headers $h -TimeoutSec 20
    } catch { $meta = $null }
}

$lines = @(
    '==========================================',
    ' vpsmajani - Windows RDP (auto-renewing)',
    '==========================================',
    '',
    " Session          : $SessionNumber",
    " Started          : $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    " Computer         : $env:COMPUTERNAME",
    " Tailscale IP     : $TailscaleIP",
    '',
    ' --- Persistence -------------------------',
    " Sync mode        : $mode",
    " Restore status   : $($status.Trim())",
    " Snapshot on disk : $(if ($meta) { "$($meta.saved_at)  ($(Format-Bytes ([double]$meta.bytes)))" } else { 'none yet' })",
    '',
    ' --- Good to know ------------------------',
    ' Each session lives ~40 minutes, then this VM is replaced',
    ' by a fresh one. Your profile is snapshotted before the',
    ' swap and restored on the next machine, so files reappear',
    ' (usually within a minute after you connect).',
    '',
    ' The first session of a pair is an empty machine: it saves,',
    ' it cannot restore. Do not panic - reconnect to the new',
    ' session and the files are back.',
    '',
    ' Keep big files inside your user profile, not on random',
    ' system folders. Close apps before the session ends so',
    ' their files are not locked during the snapshot.',
    '=========================================='
)

$lines | Set-Content -Path (Join-Path $desktop 'STATUS.txt') -Encoding UTF8
Say "[info] wrote $desktop\STATUS.txt"
Say "[info] $status"

exit 0
