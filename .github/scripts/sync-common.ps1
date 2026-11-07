# Shared helpers for the desktop snapshot scripts (save + restore).
# Dot-source it:  . "$PSScriptRoot\sync-common.ps1"

$script:SyncMode = ($env:SYNC_MODE, 'local')[0]
if (-not $script:SyncMode) { $script:SyncMode = 'local' }

function Get-SyncMode { $script:SyncMode }

# Which Windows account holds the user's data. Overridable for tests.
function Get-ProfileUser {
    if ($env:SYNC_PROFILE_USER) { return $env:SYNC_PROFILE_USER }
    return 'NvDAdmin'
}

function Get-ProfilePath {
    return (Join-Path 'C:\Users' (Get-ProfileUser))
}

$script:WorkDir = 'C:\vpsmajani-sync'
function Get-SyncWorkDir { $script:WorkDir }

function Initialize-SyncWorkDir {
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
    foreach ($sub in @('state', 'log', 'tmp')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:WorkDir $sub) | Out-Null
    }
}

# Everything the user can see or create lives under C:\Users\<user>.
# We keep the whole profile folder, which covers Desktop, Documents,
# Downloads, Pictures, Videos, AppData (browser profiles, chat history...).
# Paths are relative to C:\ so the archive restores back to the same place.
function Get-PreservedPaths {
    return @(".?:\Users\$(Get-ProfileUser)")
}

# Excludes are tar patterns relative to C:\ (the archive root).
# Only caches, temp files and pagefiles - never user documents.
function Get-SyncExcludes {
    $u = "Users/$(Get-ProfileUser)"
    return @(
        "$u/AppData/Local/Temp/*"
        "$u/AppData/Local/Temp"
        "$u/AppData/Local/CrashDumps/*"
        "$u/AppData/Local/D3DSCache/*"
        "$u/AppData/Local/NVIDIA/DXCache/*"
        "$u/AppData/Local/NVIDIA/GLCache/*"
        "$u/AppData/Local/Microsoft/Windows/Explorer/ThumbCache*"
        "$u/AppData/Local/Microsoft/Edge/User Data/*/Cache/*"
        "$u/AppData/Local/Google/Chrome/User Data/*/Cache/*"
        "$u/AppData/Local/Google/Chrome/User Data/*/Code Cache/*"
        "$u/AppData/Local/Packages/*/LocalCache/*"
        "$u/AppData/Local/Packages/*/TempState/*"
        "$u/AppData/Local/Packages/*/AC/Temp/*"
        "$u/AppData/Local/Application Data/*"
        "pagefile.sys"
        "swapfile.sys"
        "hiberfil.sys"
        "DumpStack.log.tmp"
    )
}

function Get-TarExe {
    $cmd = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $builtin = 'C:\Windows\System32\tar.exe'
    if (Test-Path $builtin) { return $builtin }
    return $null
}

# Run 7-Zip (bundled with the windows-latest image) as a fallback.
function Invoke-SevenZip {
    param([string[]]$Arguments)
    $candidates = @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) {
        $cmd = Get-Command 7z -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }
    if (-not $exe) { return $false }
    & $exe @Arguments
    return ($LASTEXITCODE -eq 0)
}

# Extract an archive relative to C:\ so absolute paths land back in place.
function Invoke-TarExtract {
    param([Parameter(Mandatory = $true)][string]$Archive)

    $tarExe = Get-TarExe
    if (-not $tarExe) { return $false }
    Push-Location 'C:\'
    try {
        & $tarExe -xf $Archive -C 'C:\' 2>&1 | ForEach-Object { Write-Host "   $_" }
        return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1)
    } catch {
        Write-Host "   tar error: $_"
        return $false
    } finally {
        Pop-Location
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}
