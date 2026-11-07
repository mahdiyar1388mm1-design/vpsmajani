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

$mode       = Get-SyncMode
$archive    = $null
$markerFile = $null
Initialize-SyncWorkDir
$work  = Get-SyncWorkDir
$state = Join-Path $work 'state'

Say "[save] mode=$mode session=$SessionNumber"

function Set-Status([string]$text) {
    $text | Set-Content -Path (Join-Path $state 'status.txt') -Encoding UTF8
    Say "[save] $text"
}

# A small extra file travels with every snapshot so the next session can show
# a friendly summary of where its files came from.
function Write-Marker {
    param([string]$ArchiveName, [double]$Bytes, [string]$Format)
    $path = Join-Path $work 'tmp\last-save.txt'
    @(
        "saved_at=$(Get-Date -Format o)"
        "session=$SessionNumber"
        "host=$env:COMPUTERNAME"
        "mode=$mode"
        "archive=$ArchiveName"
        "bytes=$Bytes"
        "format=$Format"
        "profile=$(Get-ProfileUser)"
    ) | Set-Content -Path $path -Encoding UTF8
    return $path
}

$profilePath = Get-ProfilePath
if (-not (Test-Path $profilePath)) {
    Write-Host "::warning title=Nothing to save::The profile folder $profilePath does not exist yet, nothing to snapshot."
    Set-Status 'Nothing to save yet: the profile folder does not exist.'
    exit 0
}

# --- disk space guard -------------------------------------------------------
$free = (Get-PSDrive C).Free
Say ("[save] free disk: {0}" -f (Format-Bytes $free))
if ($free -lt 1GB) {
    Write-Host '::warning title=Snapshot skipped::Less than 1 GB free on C:, not enough room to build the archive.'
    Set-Status 'Snapshot skipped: not enough free disk space.'
    exit 0
}

$started = Get-Date

# Make room for leftovers from an interrupted run.
Get-ChildItem -Path $work -Filter 'snapshot-*' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 2 | Remove-Item -Force -ErrorAction SilentlyContinue

# --- build the archive ------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$tarPath = Join-Path $work "snapshot-$stamp.tar"
$gzPath  = "$tarPath.gz"
Remove-Item -Force $tarPath, $gzPath -ErrorAction SilentlyContinue

$tarExe = Get-TarExe
$ok = $false

if ($tarExe) {
    Say "[save] collecting files with $tarExe ..."
    $args = @('-cf', $tarPath, '-C', 'C:\')
    foreach ($ex in Get-SyncExcludes) { $args += "--exclude=$ex" }
    foreach ($inc in Get-PreservedPaths) { $args += $inc }

    Push-Location 'C:\'
    try {
        & $tarExe @args 2>&1 | ForEach-Object { Say "   $_" }
        $ok = ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1)   # 1 = some files vanished mid-run
    } catch {
        Say "[save] tar error: $_"
        $ok = $false
    } finally {
        Pop-Location
    }
}

if ($ok -and (Test-Path $tarPath) -and (Get-Item $tarPath).Length -gt 1024) {
    Say ("[save] compressing {0} ..." -f (Format-Bytes (Get-Item $tarPath).Length))
    if (Compress-GzipFile -Path $tarPath -Destination $gzPath) {
        Remove-Item -Force $tarPath -ErrorAction SilentlyContinue
        $archive = $gzPath
    } else {
        $usedTar = End-TarFallback -TarPath $tarPath
        $archive = $usedTar
    }
}

# 7-Zip fallback if tar is missing or produced nothing usable.
if (-not $archive -or -not (Test-Path $archive) -or (Get-Item $archive).Length -lt 1024) {
    Say '[save] tar did not produce a usable archive, trying 7-Zip'
    $sevenZ = Join-Path $work "snapshot-$stamp.7z"
    $ok7 = Invoke-SevenZip -Arguments @('a', '-t7z', '-mx=1', $sevenZ, $profilePath)
    if ($ok7 -and (Test-Path $sevenZ) -and (Get-Item $sevenZ).Length -gt 1024) {
        $archive = $sevenZ
    } else {
        $archive = $null
    }
}

if (-not $archive) {
    Write-Host '::warning title=Snapshot failed::No usable archive could be created.'
    Set-Status 'Snapshot failed: no usable archive could be created.'
    exit 0
}

$size   = (Get-Item $archive).Length
$secs   = [int]((Get-Date) - $started).TotalSeconds
$format = if ($archive -like '*.7z') { '7z' } else { 'tar.gz' }
$sha    = (Get-FileHash -Path $archive -Algorithm SHA256).Hash

Say ("[save] archive: {0} ({1}, {2}) in {3}s" -f (Split-Path $archive -Leaf), (Format-Bytes $size), $format, $secs)
Say "[save] sha256=$sha"

$markerFile = Write-Marker -ArchiveName (Split-Path $archive -Leaf) -Bytes $size -Format $format

# --- ship it ----------------------------------------------------------------
$sent = $false
if ($mode -eq 'http') {
    if (-not $StorageUrl) {
        Write-Host '::warning title=Snapshot not uploaded::SYNC_MODE=http but STORAGE_URL is empty.'
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{
            'X-Client-Name'            = [string]$env:COMPUTERNAME
            'X-Session-Number'         = [string]$SessionNumber
            'X-Snapshot-Format'        = $format
            'X-Snapshot-Sha256'        = $sha
            'X-Snapshot-Sha-Algorithm' = 'sha256'
        }
        if ($Token) { $headers['Authorization'] = "Bearer $Token" }

        try {
            Say "[save] uploading to $StorageUrl/snapshot ..."
            $r = Invoke-RestMethod -Method Put -Uri "$StorageUrl/snapshot" -Headers $headers `
                -InFile $archive -ContentType 'application/octet-stream' -TimeoutSec 900
            Say "[save] uploaded: $($r | ConvertTo-Json -Compress)"

            # Ship the marker too; not fatal if it fails.
            try {
                Invoke-RestMethod -Method Put -Uri "$StorageUrl/marker" -Headers $headers `
                    -InFile $markerFile -ContentType 'text/plain' -TimeoutSec 60 | Out-Null
            } catch {
                Say "[save] marker upload skipped: $($_.Exception.Message)"
            }
            $sent = $true
        } catch {
            Write-Host "::warning title=Snapshot not uploaded::Upload failed: $($_.Exception.Message)"
        }
    }
}

if ($sent) {
    Set-Status "Snapshot saved to the volume at $(Get-Date -Format 'HH:mm') ($(Format-Bytes $size))."
} elseif ($mode -eq 'local') {
    Set-Status "Snapshot kept on this VM only, no storage volume is configured ($(Format-Bytes $size))."
} else {
    Set-Status 'Snapshot created but the upload did not succeed.'
}

exit 0

# --- helpers ----------------------------------------------------------------
function End-TarFallback {
    param([string]$TarPath)
    # Keep the plain tar only if nothing else worked; the server would refuse
    # it, so it stays local.
    if (Test-Path $TarPath) {
        Say '[save] gzip failed, keeping a local .tar only'
        return $TarPath
    }
    return $null
}
