# Shared Tailscale helpers used by the other desktop-*.ps1 scripts.
# Dot-source it:  . "$PSScriptRoot\ts-common.ps1"

$script:TailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'

function Get-TailscaleExe { return $script:TailscaleExe }

function Install-Tailscale {
    if (Test-Path $script:TailscaleExe) { return }
    Write-Host '[ts] installing Tailscale...'
    Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile 'C:\tailscale.msi'
    Start-Process msiexec -ArgumentList '/i C:\tailscale.msi /quiet /norestart' -Wait
    Start-Sleep -Seconds 5
}

function Get-TailscaleIPv4 {
    if (-not (Test-Path $script:TailscaleExe)) { return $null }
    return (& $script:TailscaleExe ip -4 2>$null | Select-Object -First 1)
}

function Connect-Tailscale {
    param(
        [string]$AuthKey,
        [string]$HostName = 'github-rdp-server',
        [int]$Attempts = 6
    )
    Install-Tailscale
    for ($i = 1; $i -le $Attempts; $i++) {
        $ip = Get-TailscaleIPv4
        if ($ip) { return $ip }
        Write-Host "[ts] tailscale up (attempt $i)..."
        & $script:TailscaleExe up --authkey="$AuthKey" --hostname="$HostName" 2>&1 | Out-Host
        Start-Sleep -Seconds 8
    }
    return (Get-TailscaleIPv4)
}

# All other nodes in the tailnet, as objects: HostName, IP, Online
function Get-TailscalePeers {
    if (-not (Test-Path $script:TailscaleExe)) { return @() }
    $raw = & $script:TailscaleExe status --json 2>$null
    if (-not $raw) { return @() }
    try { $st = $raw | ConvertFrom-Json } catch { return @() }
    if (-not $st.Peer) { return @() }

    $out = @()
    foreach ($prop in $st.Peer.PSObject.Properties) {
        $p = $prop.Value
        $v4 = @($p.TailscaleIPs | Where-Object { $_ -like '*.*' }) | Select-Object -First 1
        if (-not $v4) { continue }
        $out += [pscustomobject]@{
            HostName = [string]$p.HostName
            IP       = [string]$v4
            Online   = [bool]$p.Online
        }
    }
    return $out
}

# Peers that look like one of our RDP sessions (including our own name with a
# -1 / -2 suffix when two sessions briefly overlap during a handover).
function Get-RdpPeers {
    param([string]$NamePrefix = 'github-rdp-server')
    return @(Get-TailscalePeers | Where-Object {
            $_.Online -and $_.HostName -like "$NamePrefix*"
        } | Sort-Object HostName)
}
