# Takes a snapshot of the user's profile and hands it to the storage VPS.
# Runs a final time right before the session dies.
#
# Exit code is always 0: a failed backup must never break the chain.
#
#   SYNC_MODE=local  (default) archive is kept on this VM only
#   SYNC_MODE=http             archive is uploaded to STORAGE_URL

param(
    [string]$StorageUrl = $env:STORAGE_URL,
    [string]$Token      = $env:SYNC_TOKEN,
    [int]$SessionNumber = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\sync-common.ps1"

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

$mode = Get-SyncMode
Initialize-SyncWorkDir
$work  = Get-SyncWorkDir
$state = Join-Path $work 'state'
$log   = Join-Path $work 'log\save.log'

Say "[save] mode=$mode session=$SessionNumber"

$paths = Get-PreservedPaths
$missing = @($paths | Where-Object { -not (Test-Path $_) })
if ($missing.Count -eq $paths.Count) {
    Write-Host '::warning title=Nothing to save::The profile folder does not exist yet, nothing to snapshot.'
    exit 0
}

# --- disk space guard -------------------------------------------------------
$free = (Get-PSDrive C).Free
Say ("[save] free disk: {0}" -f (Format-Bytes $free))
if ($free -lt 1GB) {
    Write-Host '::warning title=Snapshot skipped::Less than 1 GB free on C:, not enough room to build the archive.'
    exit 0
}

# --- build the archive ------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$archive = Join-Path $work "snapshot-$stamp.tar.gz"
$tmpDir  = Join-Path $work 'data'
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

# What we *intend* to keep, for the archive map files.
$paths | Set-Content -Path (Join-Path $tmpDir 'paths.txt') -Encoding UTF8

Say '[save] collecting files...'
$started = Get-Date
$ok = Invoke-SevenZip -Arguments @(
    'a', '-ttar', '-so', $archive,
    '--', ($paths | ForEach-Object { "$($_)" })
)

if (-not $ok -or -not (Test-Path $archive) -or (Get-Item $archive).Length -lt 1024) {
    Say '[save] 7-Zip unavailable or failed, falling back to Compress-Archive'
    try {
        $zip = Join-Path $work "snapshot-$stamp.zip"
        Compress-Archive -Path ($paths | Where-Object { Test-Path $_ }) -DestinationPath $zip `
            -CompressionLevel Optimal -Force -ErrorAction Stop
        $archive = $zip
    } catch {
        Write-Host "::warning title=Snapshot failed::Could not create the archive: $($_.Exception.Message)"
        exit 0
    }
}

$size = (Get-Item $archive).Length
$secs = [int]((Get-Date) - $started).TotalSeconds
Say ("[save] archive: {0} ({1}) in {2}s" -f (Split-Path $archive -Leaf), (Format-Bytes $size), $secs)

# gzip it (7-Zip wrote a plain tar)
if ($archive -like '*.tar') {
    $gz = "$archive.gz"
    $okGz = Invoke-SevenZip -Arguments @('a', '-tgzip', '-mx=3', $gz, $archive)
    if ($okGz) { Remove-Item $archive -Force -ErrorAction SilentlyContinue; $archive = $gz }
    $size = (Get-Item $archive).Length
}

$sha = (Get-FileHash -Path $archive -Algorithm SHA256).Hash
$meta = @(
    "saved_at=$(Get-Date -Format o)"
    "session=$SessionNumber"
    "host=$env:COMPUTERNAME"
    "mode=$mode"
    "bytes=$size"
    "sha256=$sha"
    "file=$(Split-Path $archive -Leaf)"
)
$meta | Set-Content -Path (Join-Path $work 'last-save.txt') -Encoding UTF8
Say "[save] sha256=$sha"

# --- ship it ----------------------------------------------------------------
function Send-Payload {
    param([string]$Path)

    if ($mode -ne 'http') { return $false }
    if (-not $StorageUrl) {
        Write-Host '::warning title=Snapshot not uploaded::SYNC_MODE=http but STORAGE_URL is empty.'
        return $false
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'X-Client-Name'     = [string]$env:COMPUTERNAME
        'X-Session-Number'  = [string]$SessionNumber
    }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }

    try {
        Say "[save] uploading to $StorageUrl/snapshot ..."
        $r = Invoke-RestMethod -Method Put -Uri "$StorageUrl/snapshot" -Headers $headers `
            -InFile $Path -ContentType 'application/gzip' -TimeoutSec 900
        Say "[save] uploaded: $($r | ConvertTo-Json -Compress)"
        return $true
    } catch {
        Write-Host "::warning title=Snapshot not uploaded::Upload failed: $($_.Exception.Message)"
        return $false
    }
}

$sent = Send-Payload -Path $archive

# Keep the last two archives locally so a same-VM retry has something.
Get-ChildItem -Path $work -Filter 'snapshot-*' -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 2 | Remove-Item -Force -ErrorAction SilentlyContinue

if ($sent) {
    Say '[save] done: desktop is safe on the storage volume.'
} elseif ($mode -eq 'local') {
    Say "[save] done (local mode): archive kept at $archive on this VM only."
} else {
    Say '[save] done, but the upload did not succeed (see warning).'
}

exit 0
