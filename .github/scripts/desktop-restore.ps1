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
    Set-Status 'No storage volume configured (SYNC_MODE=local). Files from previous sessions are not restored.'
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
    Set-Status "Storage volume is empty or unreachable ($($_.Exception.Message)). Starting with a clean desktop."
    exit 0
}

Say "[restore] snapshot from $($meta.saved_at) ($(Format-Bytes ([double]$meta.bytes)))"

# --- download ---------------------------------------------------------------
$incoming = Join-Path $work 'restore.incoming'
$archive  = Join-Path $work 'restore.tar.gz'
Remove-Item -Force $incoming, $archive -ErrorAction SilentlyContinue

try {
    Say '[restore] downloading snapshot...'
    Invoke-WebRequest -Method Get -Uri "$StorageUrl/snapshot" -Headers $headers `
        -OutFile $incoming -TimeoutSec 900 -UseBasicParsing
} catch {
    Set-Status "Snapshot download failed ($($_.Exception.Message)). Starting with a clean desktop."
    exit 0
}

$size = (Get-Item $incoming).Length
if ($size -lt 1024) {
    Set-Status "Downloaded snapshot looks empty ($size bytes). Starting with a clean desktop."
    exit 0
}
Say ("[restore] downloaded {0}" -f (Format-Bytes $size))

if ($meta.sha256) {
    $actual = (Get-FileHash -Path $incoming -Algorithm SHA256).Hash
    if ($actual -ne $meta.sha256) {
        Write-Host "::warning title=Snapshot corrupt::sha256 mismatch ($actual vs $($meta.sha256)), not restoring."
        Set-Status 'Snapshot was corrupt (sha256 mismatch). Starting with a clean desktop.'
        exit 0
    }
    Say '[restore] sha256 verified.'
}
Move-Item -Force $incoming $archive

# --- unpack -----------------------------------------------------------------
$isGzip = $false
$fs = [IO.File]::OpenRead($archive)
try { $isGzip = ($fs.ReadByte() -eq 0x1f -and $fs.ReadByte() -eq 0x8b) } finally { $fs.Close() }

Say '[restore] unpacking...'
$target = 'C:\'
$ok = Invoke-SevenZip -Arguments @('x', '-y', "-o$target", $archive)

if (-not $ok) {
    if ($isGzip) {
        $tar = Join-Path $work 'restore.tar'
        if (Invoke-SevenZip -Arguments @('x', '-y', "-o$work", $archive)) {
            if (Test-Path $tar) {
                $ok = Invoke-SevenZip -Arguments @('x', '-y', "-o$target", $tar)
            }
        }
    } else {
        $ok = $false
    }
}

if ($ok -and (Test-Path 'C:\vpsmajani-sync\data\paths.txt')) {
    Say '[restore] restored paths:'
    Get-Content 'C:\vpsmajani-sync\data\paths.txt' | ForEach-Object { Say "   $_" }
}

if ($ok) {
    Set-Status "Restored snapshot from $($meta.saved_at) - your files are back."
} else {
    Set-Status 'Unpacking the snapshot failed. Starting with a clean desktop (the snapshot is still safe on the volume).'
}

exit 0
