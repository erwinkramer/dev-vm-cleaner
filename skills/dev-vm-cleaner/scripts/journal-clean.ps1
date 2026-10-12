#requires -Version 7.6
# Journal helpers: sets a 50M / 7d limit in journald.conf and vacuums the
# journal of a running distro (no admin required).
# Dot-source after helpers.ps1 (needed for Write-Log, $LogPath must be set):
#     . (Join-Path $PSScriptRoot "journal-clean.ps1")
# Never starts/stops a distro; the caller owns the distro lifecycle.

# Journal limits (single source of truth): written to the distro's
# /etc/systemd/journald.conf and mirrored by the vacuum command below.
$JournalMaxUse = "50M"
$JournalRetention = "7d"

# Journal size in MB ("Archived and active journals take up 184M in the
# file system."). Runs as root and returns 0 when unparseable.
function Get-JournalUsageMB {
    param([Parameter(Mandatory)][string]$Distro)
    $usage = (Invoke-NativeCommand -FilePath 'wsl' -Arguments @('-d', $Distro, '-u', 'root', '--', 'journalctl', '--disk-usage')).Output
    if ($usage -match '(\d+(?:\.\d+)?)\s*([KMG]) in the file system') {
        $n = [double]$matches[1]
        switch ($matches[2]) { 'K' { $n / 1024 } 'G' { $n * 1024 } default { $n } }
    } else { 0 }
}

# Make the journal self-limiting: overwrite /etc/systemd/journald.conf in
# the distro with SystemMaxUse= and MaxRetentionSec=, then SIGHUP journald
# so the running instance picks the limits up.
function Set-JournalConf {
    param([Parameter(Mandatory)][string]$Distro)
    # Overwrite the whole file: these managed distros carry no custom
    # journald settings worth preserving (idempotent, one WSL session).
    $conf = "[Journal]`nSystemMaxUse=$JournalMaxUse`nMaxRetentionSec=$JournalRetention`n"
    $null = $conf | wsl -d $Distro -u root -e tee /etc/systemd/journald.conf 2>&1
    Write-Log "Wrote journald.conf (SystemMaxUse=$JournalMaxUse, MaxRetentionSec=$JournalRetention) - reloading journald"
    $null = wsl -d $Distro -u root systemctl kill -s HUP systemd-journald.service 2>&1
}

# Vacuum the systemd journal inside a *running* distro (journal files are
# root-owned and some distros - e.g. podman-machine-default - default to a
# non-root user, so run as root). Call this *before* stopping the distro /
# compacting the VHDX.
function Invoke-JournalCleanup {
    param([Parameter(Mandatory)][string]$Distro)

    Set-JournalConf -Distro $Distro
    Write-Log "Vacuuming systemd journal (limits from /etc/systemd/journald.conf)..."
    $before = Get-JournalUsageMB -Distro $Distro
    Write-Log ("Journal usage before: {0:0.0} MB" -f $before)
    # Mirror the limits from above so vacuum matches what conf enforces
    $null = wsl -d $Distro -u root journalctl --vacuum-time=$JournalRetention --vacuum-size=$JournalMaxUse 2>&1
    $after = Get-JournalUsageMB -Distro $Distro
    Write-Log ("Journal usage after:  {0:0.0} MB" -f $after)
}
