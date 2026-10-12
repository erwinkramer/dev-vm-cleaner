#requires -Version 7.6
# Clear supported host-user package caches once, independently of WSL distro cleanup.

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot ? $PSScriptRoot : (Get-Location).Path
$LogPath = Join-Path (Split-Path $scriptDir) "logs", "host_cleanup.log"
$null = New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force
. (Join-Path $scriptDir "helpers.ps1")

$cleaners = @(
    @{ Name = 'NuGet HTTP'; Command = 'dotnet.exe'; Arguments = @('nuget', 'locals', 'http-cache', '--clear'); IgnoreLocked = $true }
    @{ Name = 'NuGet packages'; Command = 'dotnet.exe'; Arguments = @('nuget', 'locals', 'global-packages', '--clear'); IgnoreLocked = $true }
    @{ Name = 'NuGet temp'; Command = 'dotnet.exe'; Arguments = @('nuget', 'locals', 'temp', '--clear'); IgnoreLocked = $true }
    @{ Name = 'NuGet plugins'; Command = 'dotnet.exe'; Arguments = @('nuget', 'locals', 'plugins-cache', '--clear'); IgnoreLocked = $true }
    @{ Name = 'npm'; Command = 'npm.cmd'; Arguments = @('cache', 'clean', '--force') }
    @{ Name = 'pnpm'; Command = 'pnpm.cmd'; Arguments = @('store', 'prune'); Corepack = $true }
    @{ Name = 'Yarn'; Command = 'yarn.cmd'; Arguments = @('cache', 'clean') }
    @{ Name = 'Composer'; Command = 'composer.bat'; Arguments = @('clear-cache') }
)
$python = Get-Command 'py.exe' -CommandType Application -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command 'python.exe' -CommandType Application -ErrorAction SilentlyContinue }
if ($python) {
    $cleaners += @{ Name = 'pip'; Path = $python.Source; Arguments = @('-m', 'pip', 'cache', 'purge') }
}
$failed = $false

try {
    Write-Log "=== Host cache cleanup ==="
    foreach ($cleaner in $cleaners) {
        $command = if ($cleaner.Path) {
            $cleaner.Path
        } else {
            (Get-Command $cleaner.Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        }
        if (-not $command) { continue }

        $previousCorepackNetwork = $env:COREPACK_ENABLE_NETWORK
        $previousCorepackPrompt = $env:COREPACK_ENABLE_DOWNLOAD_PROMPT
        if ($cleaner.Corepack) {
            $env:COREPACK_ENABLE_NETWORK = '0'
            $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
        }
        try {
            Write-Log "Clearing $($cleaner.Name) cache..."
            $cleanup = Invoke-NativeCommand -FilePath $command -Arguments $cleaner.Arguments
            if ($cleanup.Output) { Write-Log "$($cleaner.Name) cleanup output:`n$($cleanup.Output)" }
            if ($cleanup.ExitCode -ne 0) {
                if ($cleaner.IgnoreLocked -and $cleanup.Output -match '(?i)(being used by another process|file is locked|used by another process)') {
                    Write-Log "WARNING: $($cleaner.Name) cache contains locked files; continuing" "WARN"
                } elseif ($cleaner.Corepack -and $cleanup.Output -match '(?i)(pnpm-native\.exe.*UNKNOWN|network access is disabled by the environment|blocked by group policy)') {
                    Write-Log "WARNING: pnpm could not run without Corepack's blocked native binary; skipped without downloading" "WARN"
                } else {
                    Write-Log "ERROR: $($cleaner.Name) cache cleanup failed (exit $($cleanup.ExitCode))" "ERROR"
                    $failed = $true
                }
            }
        } catch {
            if ($cleaner.Corepack) {
                Write-Log "WARNING: pnpm could not run; skipped without downloading: $_" "WARN"
            } else {
                Write-Log "ERROR: $($cleaner.Name) cache cleanup failed: $_" "ERROR"
                $failed = $true
            }
        } finally {
            if ($cleaner.Corepack) {
                $env:COREPACK_ENABLE_NETWORK = $previousCorepackNetwork
                $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = $previousCorepackPrompt
            }
        }
    }
    if ($failed) { exit 1 }
    Write-Log "=== Done ==="
} catch {
    Write-Log "ERROR: $_" "ERROR"
    exit 1
}