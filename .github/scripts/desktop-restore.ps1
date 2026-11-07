# Restores the snapshot taken by the previous session.
# Exit code is always 0: a failed restore must never break the chain.
#
#   SYNC_MODE=local  (default) nothing to restore, writes a "no volume" marker
#   SYNC_MODE=http             downloads STORAGE_URL/snapshot and unpacks it

param(
    [string]$StorageUrl = $env:STORAGE_URL,
    [string]$Token      = $env:SYNC_TOKEN,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\sync-common.ps1"

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

$mode = Get-SyncMode
Initialize-SyncWorkDir
$work  = Get-SyncWorkDir
$state = Join-Path $work 'state'

Say "[restore] mode=$mode"

function Set-Status([string]$text) {
    $text | Set-Content -Path (Join-Path $state 'status.txt') -Encoding UTF8
    Say "[restore] $text"
}

if ($mode -ne 'http' -or -not $StorageUrl) {
    if ($mode -eq 'http' -and -not $StorageUrl) {
        Write-Host '::warning title=Restore skipped::SYNC_MODE=http but STORAGE_URL is empty.'
    }
    Set-Status 'No storage volume configured, so nothing from a previous session can be restored.'
    exit 0
}

# --- is there anything to restore? -----------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{}
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

$meta = $null
try {
    $meta = Invoke-RestMethod -Method Get -Uri "$StorageUrl/meta" -Headers $headers -TimeoutSec 30
} catch {
    Set-Status "The storage volume is empty or unreachable ($($_.Exception.Message)). Starting with a clean desktop."
    exit 0
}

Say ("[restore] snapshot from {0} ({1})" -f $meta.saved_at, (Format-Bytes ([double]$meta.bytes)))

# --- download ---------------------------------------------------------------
$incoming = Join-Path $work 'tmp\restore.incoming'
Remove-Item -Force $incoming -ErrorAction SilentlyContinue

try {
    Say '[restore] downloading snapshot...'
    Invoke-WebRequest -Method Get -Uri "$StorageUrl/snapshot" -Headers $headers `
        -OutFile $incoming -TimeoutSec 900 -UseBasicParsing
} catch {
    Set-Status "Downloading the snapshot failed ($($_.Exception.Message)). Starting with a clean desktop."
    exit 0
}

$size = (Get-Item $incoming).Length
if ($size -lt 1024) {
    Set-Status "The downloaded snapshot looks empty ($size bytes). Starting with a clean desktop."
    exit 0
}
Say ("[restore] downloaded {0}" -f (Format-Bytes $size))

if ($meta.sha256 -and $meta.sha_algorithm -and $meta.sha_algorithm -ne 'none') {
    try {
        $actual = (Get-FileHash -Path $incoming -Algorithm $meta.sha_algorithm).Hash
        if ($actual -ne $meta.sha256) {
            Write-Host "::warning title=Snapshot corrupt::Checksum mismatch ($actual vs $($meta.sha256)), not restoring."
            Set-Status 'The snapshot was corrupt (checksum mismatch). Starting with a clean desktop; the old copy is still on the volume.'
            exit 0
        }
        Say '[restore] checksum verified.'
    } catch {
        Say "[restore] checksum check skipped: $_"
    }
}

$format = ''
if ($meta.format) { $format = [string]$meta.format }
if ($format -match '7z') {
    $archive = Join-Path $work 'restore.7z'
} else {
    $archive = Join-Path $work 'restore.tar.gz'
}
Move-Item -Force $incoming $archive

# --- unpack -----------------------------------------------------------------
Say '[restore] unpacking into C:\ ...'
$ok = (Invoke-TarExtract -Archive $archive)
if (-not $ok) {
    Say '[restore] tar failed, trying 7-Zip'
    $ok = Invoke-SevenZip -Arguments @('x', '-y', '-oC:\', $archive)
    if (-not $ok -and $archive -like '*.tar.gz') {
        # 7-Zip may need two passes for gz -> tar.
        $inner = Join-Path $work 'tmp\restore.tar'
        if (Invoke-SevenZip -Arguments @('x', '-y', "-o$(Split-Path $inner -Parent)", $archive) -and (Test-Path $inner)) {
            $ok = Invoke-SevenZip -Arguments @('x', '-y', '-oC:\', $inner)
        }
    }
}

# Unblock files that came from another machine (SmartScreen marks them).
try {
    Get-ChildItem -Path (Get-ProfilePath) -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -lt 50MB } |
        Unblock-File -ErrorAction SilentlyContinue
} catch { }

if ($ok) {
    Set-Status "Restored the snapshot from $($meta.saved_at). Your files should be back."
} else {
    Set-Status 'Unpacking the snapshot failed. Starting with a clean desktop (the snapshot is still safe on the volume).'
}

exit 0
