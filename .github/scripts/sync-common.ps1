# Shared helpers for the desktop snapshot scripts (save + restore).
# Dot-source it:  . "$PSScriptRoot\sync-common.ps1"

$script:SyncMode = ($env:SYNC_MODE, 'local')[0]
if (-not $script:SyncMode) { $script:SyncMode = 'local' }

function Get-SyncMode { $script:SyncMode }

$script:WorkDir = 'C:\vpsmajani-sync'
function Get-SyncWorkDir { $script:WorkDir }

function Initialize-SyncWorkDir {
    New-Item -ItemType Directory -Force -Path $script:WorkDir   | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:WorkDir 'data')  | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:WorkDir 'state') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:WorkDir 'log')   | Out-Null
}

# Everything the user can see or create lives under C:\Users\<user>.
# We keep the whole profile folder, which covers Desktop, Documents,
# Downloads, Pictures, Videos, AppData (browser profiles, chat history...).
function Get-PreservedPaths {
    param([string]$User = 'NvDAdmin')
    $usersRoot = 'C:\Users'
    $paths = @(
        (Join-Path $usersRoot $User)
    )
    $legacyData = 'C:\vpsmajani-data'
    if (Test-Path $legacyData) { $paths += $legacyData }
    return $paths
}

# Exclusions: things that are large, regenerable, or actively locked by
# Windows. They are documented in README so nothing is hidden from the user.
function Get-SyncExcludes {
    $common = @(
        'AppData\Local\Packages\*_8wekyb3d8bbwe\LocalCache\*'   # Store app caches
        'AppData\Local\Packages\*_8wekyb3d8bbwe\TempState\*'
        'AppData\Local\Microsoft\Edge\User Data\Default\Cache\*'
        'AppData\Local\Google\Chrome\User Data\Default\Cache\*'
        'AppData\Local\Google\Chrome\User Data\Default\Code Cache\*'
        'AppData\Local\Temp\*'
        'AppData\Local\CrashDumps\*'
        'AppData\Local\D3DSCache\*'
        'AppData\Local\NVIDIA\DXCache\*'
        'AppData\Local\NVIDIA\GLCache\*'
        'AppData\Local\Packages\*'
        '*.tmp'
        '*.etl'
        'pagefile.sys'
        'swapfile.sys'
        'hiberfil.sys'
    )
    return $common
}

# Run 7-Zip (bundled with the windows-latest image). Returns $false when it is
# not available so the caller can fall back to Compress-Archive.
function Invoke-SevenZip {
    param([string[]]$Arguments)
    $candidates = @(
        'C:\Program Files\7-Zip\7z.exe'
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) {
        $cmd = Get-Command 7z -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }
    if (-not $exe) { return $false }
    & $exe @Arguments
    return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1)   # 7z exit 1 = warnings
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}
