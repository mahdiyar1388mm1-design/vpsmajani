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

Say "[save] mode=$mode session=$SessionNumber"

$profilePath = Get-ProfilePath
if (-not (Test-Path $profilePath)) {
    Write-Host "::warning title=Nothing to save::The profile folder $profilePath does not exist yet, nothing to snapshot."
    exit 0
}

function Set-Status([string]$text) {
    $text | Set-Content -Path (Join-Path $state 'status.txt') -Encoding UTF8
    Say "[save] $text"
}

# --- disk space guard -------------------------------------------------------
$free = (Get-PSDrive C).Free
Say ("[save] free disk: {0}" -f (Format-Bytes $free))
if ($free -lt 1GB) {
    Write-Host '::warning title=Snapshot skipped::Less than 1 GB free on C:, not enough room to build the archive.'
    Set-Status 'Snapshot skipped: not enough free disk space.'
    exit 0
}

# --- build the archive ------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$archive = Join-Path $work "snapshot-$stamp.tar.gz"
Remove-Item -Force $archive -ErrorAction SilentlyContinue

$tarExe = Get-TarExe
$started = Get-Date
$ok = $false

if ($tarExe) {
    Say "[save] collecting files with $tarExe ..."
    $args = @('-cf', $archive, '-C', 'C:\')

    # Keep the archive honest: one file describing what is inside.
    $manifest = Join-Path $work 'tmp\preserved-paths.txt'
    (Get-PreservedPaths) | Set-Content -Path $manifest -Encoding UTF8
    $args += @('-C', (Split-Path $manifest -Parent), (Split-Path $manifest -Leaf))

    foreach ($ex in Get-SyncExcludes) { $args += "--exclude=$ex" }

    # Work relative to C:\ so paths in the archive are the real ones.
    Push-Location 'C:\'
    try {
        & $tarExe @args 2>&1 | ForEach-Object { Say "   $_" }
        $ok = ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1)   # tar exit 1 = some files vanished mid-run
    } catch {
        Say "[save] tar error: $_"
        $ok = $false
    } finally {
        Pop-Location
    }
}

if (-not $ok -or -not (Test-Path $archive) -or (Get-Item $archive).Length -lt 1024) {
    Say '[save] tar failed or produced nothing usable, trying 7-Zip'
    $fallback = Join-Path $work "snapshot-$stamp.7z"
    $ok = Invoke-SevenZip -Arguments @(
        'a', '-t7z', '-mx=1', $fallback, ($profilePath), (Join-Path $work 'tmp\preserved-paths.txt')
    )
    if ($ok -and (Test-Path $fallback)) { $archive = $fallback }
}

if (-not (Test-Path $archive) -or (Get-Item $archive).Length -lt 1024) {
    Write-Host '::warning title=Snapshot failed::No usable archive could be created.'
    Set-Status 'Snapshot failed: no usable archive could be created.'
    exit 0
}

$size = (Get-Item $archive).Length
$secs = [int]((Get-Date) - $started).TotalSeconds
Say ("[save] archive: {0} ({1}) in {2}s" -f (Split-Path $archive -Leaf), (Format-Bytes $size), $secs)

$sha = (Get-FileHash -Path $archive -Algorithm SHA256).Hash
$script:ArchiveFormat = if ($archive -like '*.7z') { '7z' } else { 'tar.gz' }
$meta = @(
    "saved_at=$(Get-Date -Format o)"
    "session=$SessionNumber"
    "host=$env:COMPUTERNAME"
    "mode=$mode"
    "bytes=$size"
    "sha256=$sha"
    "sha_algorithm=sha256"
    "file=$(Split-Path $archive -Leaf)"
    "format=$([IO.Path]::GetExtension($archive).TrimStart('.'))"
    "profile=$profilePath"
)
Set-Content -Path (Join-Path $work 'last-save.txt') -Value $meta -Encoding UTF8
Say "[save] sha256=$sha"

# --- ship it ----------------------------------------------------------------
$sent = $false
if ($mode -eq 'http') {
    if (-not $StorageUrl) {
        Write-Host '::warning title=Snapshot not uploaded::SYNC_MODE=http but STORAGE_URL is empty.'
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{
            'X-Client-Name'           = [string]$env:COMPUTERNAME
            'X-Session-Number'       = [string]$SessionNumber
            'X-Snapshot-Format'      = [string]$script:ArchiveFormat
            'X-Snapshot-Sha256'      = [string]$sha
            'X-Snapshot-Sha-Algorithm' = 'sha256' 
        }
        if ($Token) { $headers['Authorization'] = "Bearer $Token" }

        try {
            Say "[save] uploading to $StorageUrl/snapshot ..."
            $r = Invoke-RestMethod -Method Put -Uri "$StorageUrl/snapshot" -Headers $headers `
                -InFile $archive -ContentType 'application/gzip' -TimeoutSec 900
            Say "[save] uploaded: $($r | ConvertTo-Json -Compress)"
            $sent = $true
        } catch {
            Write-Host "::warning title=Snapshot not uploaded::Upload failed: $($_.Exception.Message)"
        }
    }
}

# Keep the last two archives locally so a same-VM retry has something.
Get-ChildItem -Path $work -Filter 'snapshot-*' -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 2 | Remove-Item -Force -ErrorAction SilentlyContinue

if ($sent) {
    Set-Status "Snapshot saved to the volume at $(Get-Date -Format 'HH:mm')."
} elseif ($mode -eq 'local') {
    Set-Status 'Snapshot saved on this VM only (local mode, no storage volume).'
} else {
    Set-Status 'Snapshot created but the upload did not succeed.'
}

exit 0
