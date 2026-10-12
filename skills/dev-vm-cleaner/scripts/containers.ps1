#requires -Version 7.6
# Container-engine helpers for Podman, Docker Desktop, and in-distro Docker:
# detect the engine, prune unused data, and stop it.
# Dot-source after helpers.ps1 (needed for Write-Log, Invoke-NativeCommand):
#     . (Join-Path $PSScriptRoot "containers.ps1")
# Never starts/stops the WSL distro itself; the caller owns that lifecycle.

# True when the named WSL distro is known to carry the given engine.
function Test-ContainerEngineInDistro {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][ValidateSet("podman", "docker")][string]$Engine
    )
    if ($Engine -eq "docker") {
        # Docker Desktop is managed through the Windows-side CLI.
        if ($Distro -eq "docker-desktop") { return $true }
        $r = Invoke-NativeCommand -FilePath 'wsl' -Arguments @(
            '-d', $Distro, '-u', 'root', '-e', 'docker', '--context', 'default', 'info'
        )
        return ($r.ExitCode -eq 0)
    }
    # Podman: checked as root inside the distro (missing binary exits 1).
    $r = Invoke-NativeCommand -FilePath 'wsl' -Arguments @(
        '-d', $Distro, '-u', 'root', '-e', 'podman', '--version'
    )
    return ($r.ExitCode -eq 0)
}

# True when the Windows-side CLI can reach the local engine (the socket
# tunnel can be stale even while the WSL distro itself is running).
function Test-ContainerEngineConnection {
    param([Parameter(Mandatory)][ValidateSet("podman", "docker")][string]$Engine)
    if (-not (Get-Command $Engine -ErrorAction SilentlyContinue)) { return $false }
    if ($Engine -eq "docker") {
        # Make sure 'docker' talks to Docker Desktop, not some remote context.
        # The Desktop WSL2 context name varies (docker-desktop, desktop-linux,
        # ...), so find it by its endpoint rather than hardcoding the name.
        $ctx = docker context ls --format '{{.Name}} {{.DockerEndpoint}}' 2>&1
        $desktop = ($ctx | Select-String -SimpleMatch 'dockerDesktopLinuxEngine' |
                    Select-Object -First 1)
        if (-not $desktop) { return $false }
        $name = ($desktop.ToString() -split ' \S+$')[0]
        $null = docker context use $name 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    # 2>&1 so stderr never reaches the host and cannot become a terminating
    # error under $ErrorActionPreference = "Stop"
    $null = & $Engine info 2>&1
    return ($LASTEXITCODE -eq 0)
}

# Start the engine (podman machine / Docker Desktop) when it is not running.
function Start-ContainerEngine {
    param([Parameter(Mandatory)][ValidateSet("podman", "docker")][string]$Engine)
    if ($Engine -eq "podman") {
        $null = podman machine start 2>&1
        return
    }
    # Prefer the 'docker desktop' CLI plugin (recent Docker CLIs); fall back
    # to launching the Desktop app directly.
    $null = docker desktop version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $null = docker desktop start 2>&1
    } else {
        $exe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
        if (Test-Path $exe) { Start-Process $exe }
        else { throw "Docker Desktop CLI plugin missing and '$exe' not found" }
    }
}

# Prune unused containers, images, and volumes. In-distro Docker uses its
# local default context; Podman and Docker Desktop use the Windows-side CLI.
# The Windows-side path starts an unreachable engine and waits up to ~30s.
function Invoke-ContainerEnginePrune {
    param(
        [Parameter(Mandatory)][ValidateSet("podman", "docker")][string]$Engine,
        [string]$Distro = "docker-desktop"
    )
    $inDistroDocker = $Engine -eq "docker" -and $Distro -ne "docker-desktop"
    if ($inDistroDocker) {
        $commandPath = 'wsl'
        $commandPrefix = @('-d', $Distro, '-u', 'root', '-e', 'docker', '--context', 'default')
    } else {
        if (-not (Get-Command $Engine -ErrorAction SilentlyContinue)) {
            Write-Log "Windows '$Engine' CLI not found - skipping $Engine prune" -Level "WARN"
            return
        }
        $connected = Test-ContainerEngineConnection -Engine $Engine
        if (-not $connected) {
            Write-Log "$Engine unreachable - starting it..."
            Start-ContainerEngine -Engine $Engine
            for ($i = 0; $i -lt 15 -and -not $connected; $i++) {
                Start-Sleep -Seconds 2
                $connected = Test-ContainerEngineConnection -Engine $Engine
            }
            if (-not $connected) { throw "$Engine still unreachable after start attempt" }
        }
        $commandPath = $Engine
        $commandPrefix = @()
    }
    # Identical flags for both engines: --all covers unused containers and
    # images, --volumes adds unused volumes (podman: named ones too), and
    # --force skips the confirmation prompt. (The -v/-a shorthands were
    # dropped in newer Docker CLIs, so use the long forms everywhere.)
    $pruneArgs = @("system", "prune", "--all", "--volumes", "--force")
    Write-Log "Pruning unused $Engine containers, images, and volumes..."
    $prune = Invoke-NativeCommand -FilePath $commandPath -Arguments ($commandPrefix + $pruneArgs)
    if ($prune.ExitCode -ne 0) {
        throw "$Engine prune failed (exit $($prune.ExitCode)): $($prune.Output)"
    }
    Write-Log "$Engine prune output:`n$($prune.Output)"

    if ($Engine -eq "docker") {
        Write-Log "Pruning Docker BuildKit build cache..."
        $buildPruneArgs = $commandPrefix + @("builder", "prune", "--force")
        $buildPrune = Invoke-NativeCommand -FilePath $commandPath -Arguments $buildPruneArgs
        if ($buildPrune.ExitCode -ne 0) {
            Write-Log "Docker BuildKit cache prune failed (exit $($buildPrune.ExitCode)): $($buildPrune.Output)" -Level "WARN"
        } else {
            Write-Log "Docker BuildKit cache prune output:`n$($buildPrune.Output)"
        }
    }
}

# Stop the engine so its WSL distro can be terminated cleanly (idempotent).
function Stop-ContainerEngine {
    param(
        [Parameter(Mandatory)][ValidateSet("podman", "docker")][string]$Engine,
        [string]$Distro = "docker-desktop"
    )
    if ($Engine -eq "podman") {
        $null = podman machine stop 2>&1
        return
    }
    if ($Distro -ne "docker-desktop") {
        Write-Log "In-distro Docker will stop when '$Distro' is terminated"
        return
    }
    $null = docker desktop stop 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Missing 'docker desktop' plugin or already stopped; the caller's
        # 'wsl --terminate' still releases the VHDX locks.
        Write-Log "Could not stop Docker Desktop via 'docker desktop stop' - terminating its distros instead" -Level "WARN"
    }
}
