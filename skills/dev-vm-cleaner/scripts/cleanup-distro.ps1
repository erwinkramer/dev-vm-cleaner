#requires -Version 7.6
# Unattended WSL distro cleaner: clears the WSL package manager cache
# (apt/dnf/dnf5/yum/apk/pacman/zypper), rotated dmesg files, and active logs
# (forced logrotate), vacuums the systemd journal, prunes Podman/Docker
# resources when the distro belongs to a container engine, compacts the distro's
# ext4.vhdx, caps its disk allocation, and sets the .wslconfig default disk
# size (defaultVhdSize) for newly created distros.
# (No admin required.)
# For Docker Desktop pass -Distro docker-desktop.
param(
    [string]$Distro = "Ubuntu",
    [string]$MaxDiskSize = ""
)

$ErrorActionPreference = "Stop"
$logDir = $PSScriptRoot ? $PSScriptRoot : (Get-Location).Path
$LogPath = Join-Path (Split-Path $logDir) "logs", "distro_cleanup.log"
$null = New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force
. (Join-Path $logDir "helpers.ps1")
. (Join-Path $logDir "journal-clean.ps1")
. (Join-Path $logDir "containers.ps1")

# Fixed default disk size for newly created distros: written to ~/.wslconfig
# regardless of which distro is being cleaned.
$DefaultVhdSize = "40GB"

# Per-distro defaults when -MaxDiskSize is not given (see SKILL.md).
if ([string]::IsNullOrWhiteSpace($MaxDiskSize)) {
    switch ($Distro) {
        "podman-machine-default" { $MaxDiskSize = "10GB" }
        "docker-desktop"         { $MaxDiskSize = "20GB" }
        default                  { $MaxDiskSize = "40GB" }
    }
}

try {
    Write-Log "=== WSL distro cleanup & disk compaction ($Distro) ==="

    # Fail fast before touching anything: compaction/resize need a recent WSL.
    if (-not (Test-WslVersion)) {
        throw "WSL 3.0.0 or newer required for 'wsl --manage --compact/--resize'. Update WSL and re-run."
    }

    # 1. Small cleanups inside WSL (the wsl CLI starts the distro if stopped):
    #    forced log rotation + rotated dmesg files + the detected package
    #    manager's cache.
    Write-Log "Running pm-clean.sh in '$Distro' (system/developer caches and log rotation)..."
    # Feed the script via stdin (sh -) instead of a path: distros differ in
    # how they mount Windows drives (/mnt/c vs /mnt/host/c vs not at all).
    $cleanup = Invoke-NativeCommand -FilePath 'wsl' -Arguments @(
        '-d', $Distro, '-u', 'root', '-e', 'sh', '-'
    ) -StdinFile (Join-Path $logDir 'pm-clean.sh')
    # Best-effort step: log failures but keep going - compaction/resize are
    # the primary goal and are validated separately below.
    if ($cleanup.ExitCode -ne 0) {
        Write-Log "WARNING: pm-clean.sh failed in '$Distro' (exit $($cleanup.ExitCode)); continuing" "WARN"
    }
    Write-Log "pm-clean.sh output ($Distro):`n$($cleanup.Output)"

    # 2. Vacuum the systemd journal while the distro is still up
    #    (never auto-limited on WSL; easily >300 MB over a few boots)
    Invoke-JournalCleanup -Distro $Distro

    # 3. If this distro carries a container engine, prune it, then stop it
    #    (clean engine shutdown) so step 4 can terminate it.
    foreach ($engine in @("podman", "docker")) {
        if (-not (Test-ContainerEngineInDistro -Distro $Distro -Engine $engine)) { continue }
        Write-Log "$engine detected in '$Distro'"
        Invoke-ContainerEnginePrune -Engine $engine -Distro $Distro
        Write-Log "Stopping $engine..."
        Stop-ContainerEngine -Engine $engine -Distro $Distro
    }

    # 4. Terminate the distro to release its VHDX lock.
    Stop-WslDistro -Distro $Distro

    # 5. Compact the disk + 6. cap the disk allocation.
    $vhdx = Get-WslVhdx -Distro $Distro
    if (-not $vhdx -or -not (Test-Path $vhdx)) { throw "VHDX not found for '$Distro'" }
    Invoke-VhdxCompaction -Distro $Distro -Vhdx $vhdx
    Set-WslDiskSize -Distro $Distro -Size $MaxDiskSize

    # 7. Set a fixed default disk size for newly created distros (independent
    #    of this run's -MaxDiskSize). Best effort: old WSL builds ignore the
    #    key and a failure here does not mean the cleanup failed.
    try {
        Set-WslConfigValue -Key 'defaultVhdSize' -Value $DefaultVhdSize
    } catch {
        Write-Log "WARNING: could not update ~/.wslconfig defaultVhdSize: $_" "WARN"
    }

    Write-Log "=== Done ==="
} catch {
    Write-Log "ERROR: $_" "ERROR"
    exit 1
}
