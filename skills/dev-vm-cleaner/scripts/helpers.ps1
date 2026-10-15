#requires -Version 7.6
# Shared helpers: logging, native-command runner, VHDX lookup, distro stop,
# WSL version check, VHDX compaction/resize, and .wslconfig
# management. All scripts dot-source this
# file first. Dot-source from a script that has already defined $LogPath:
#     . (Join-Path $PSScriptRoot "helpers.ps1")
$env:WSL_UTF8 = '1'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Tee-Object -FilePath $LogPath -Append
}

function Get-SizeGB {
    param([string]$Path)
    # Raw number; callers format for display with the -f operator.
    (Get-Item $Path).Length / 1GB
}

# Locate a distro's ext4.vhdx via the Lxss registry (HKCU, no admin needed).
# Returns $null when the distro isn't registered.
function Get-WslVhdx {
    param([string]$Distro)
    $reg = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DistributionName -eq $Distro }
    if ($reg) { Join-Path ($reg.BasePath -replace '^\\+\?\\', '') "ext4.vhdx" }
}

# Capture stdout and stderr separately as UTF-8.
# String -Encoding values keep this ConstrainedLanguage-compatible.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        # Optional file whose contents are piped to the command's stdin.
        [string]$StdinFile,
        [string]$ProgressMessage
    )
    $outFile = Join-Path $env:TEMP "wslcleaner_$PID.out"
    $errFile = Join-Path $env:TEMP "wslcleaner_$PID.err"
    try {
        # Start-Process redirects the file's raw bytes into stdin: unlike
        # piping a string (which re-encodes and appends a CRLF terminator,
        # leaving a stray CR that sh executes as a command), the bytes
        # reach stdin untouched.
        $processArguments = foreach ($argument in $Arguments) {
            if ($argument -match '[\s"]|^$') {
                '"' + (($argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
            } else {
                $argument
            }
        }
        $startOptions = @{
            FilePath               = $FilePath
            ArgumentList           = $processArguments
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        if ($ProgressMessage) { $null = $startOptions.Remove('Wait') }
        if ($StdinFile) { $startOptions.RedirectStandardInput = $StdinFile }
        $proc = Start-Process @startOptions
        if ($ProgressMessage) {
            while (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
                Wait-Process -Id $proc.Id -Timeout 15 -ErrorAction SilentlyContinue
                if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
                    Write-Log $ProgressMessage | Out-Host
                }
            }
        }
        $exitCode = $proc.ExitCode
        $output = (Get-Content -Raw -Encoding UTF8 $outFile -ErrorAction SilentlyContinue) +
                 (Get-Content -Raw -Encoding UTF8 $errFile -ErrorAction SilentlyContinue)
        # Plain hashtable - callers use .ExitCode/.Output.
        @{
            ExitCode = $exitCode
            Output   = ("$output").Trim()
        }
    } finally {
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

# Release the VHDX lock by terminating the distro (idempotent).
function Stop-WslDistro {
    param([string]$Distro)
    $null = wsl --terminate $Distro 2>&1
    Start-Sleep -Seconds 2
}

# Minimum WSL build supporting `wsl --manage <distro> --compact` / `--resize`.
# (Verified: 2.7.13.0 rejects both flags; 3.0.1.0 accepts them.)
function Test-WslVersion {
    param([string]$Minimum = '3.0.0.0')
    $wsl = Invoke-NativeCommand -FilePath 'wsl' -Arguments @('--version')
    if ($wsl.ExitCode -ne 0) { return $false }
    # The label is localized (e.g. English "WSL version:", Dutch "WSL-versie:"),
    # so don't match it. The first output line always ends with the WSL
    # version number, and the kernel line (second) is a different build.
    $firstLine = ($wsl.Output -split "`r?`n" | Select-Object -First 1)
    if ($firstLine -notmatch '(\d+\.\d+\.\d+\.\d+)') { return $false }
    # [Version] is on the ConstrainedLanguage allowed-types list, so -ge
    # does the component-wise compare natively.
    return ([Version]$Matches[1]) -ge ([Version]$Minimum)
}

# Compact the distro's VHDX and report space saved.
function Invoke-VhdxCompaction {
    param(
        [string]$Distro,
        [string]$Vhdx
    )
    $sizeBefore = Get-SizeGB $Vhdx
    Write-Log ("VHDX size before: {0:0.00} GB" -f $sizeBefore)
    Write-Log "Compacting disk..."
    $wsl = Invoke-NativeCommand -FilePath 'wsl' -Arguments @('--manage', $Distro, '--compact') `
        -ProgressMessage "Compaction still running for '$Distro'..."
    if ($wsl.Output) { Write-Log "WSL compact output: $($wsl.Output)" }
    if ($wsl.ExitCode -ne 0) { throw "wsl --manage $Distro --compact failed (exit $($wsl.ExitCode))" }
    $sizeAfter = Get-SizeGB $Vhdx
    Write-Log ("VHDX size after:  {0:0.00} GB" -f $sizeAfter)
    Write-Log ("Space saved:      {0:0.00} GB" -f ($sizeBefore - $sizeAfter))
}

# Set the distro's disk to an exact size via `wsl --manage <distro> --resize <size>`.
# Supported size strings: <integer><B|M|MB|G|GB|T|TB> (e.g. 512MB, 2GB).
# Decimal values are not supported (e.g. 2.5TB is rejected). Case-insensitive.
# The size must be >= the current filesystem size (resize2fs refuses to
# shrink below what's in use); the distro must be stopped.
function Set-WslDiskSize {
    param(
        [string]$Distro,
        [string]$Size
    )
    $size = $Size.ToUpperInvariant()
    if ($size -notmatch '^[1-9][0-9]*(B|M|MB|G|GB|T|TB)$') {
        throw "Invalid size string '$Size'. Expected an integer with a B/M/MB/G/GB/T/TB suffix (no decimals), e.g. 512MB or 2GB."
    }
    Write-Log "Setting disk allocation: $size..."
    $wsl = Invoke-NativeCommand -FilePath 'wsl' -Arguments @('--manage', $Distro, '--resize', $size)
    if ($wsl.ExitCode -ne 0 -and $wsl.Output -match 'Wsl/Service/E_FAIL' -and $wsl.Output -match 'recovering journal') {
        Write-Log "WSL resize hit filesystem journal recovery; retrying once in 5 seconds" -Level "WARN"
        Start-Sleep -Seconds 5
        $wsl = Invoke-NativeCommand -FilePath 'wsl' -Arguments @('--manage', $Distro, '--resize', $size)
    }
    if ($wsl.ExitCode -ne 0) {
        if ($wsl.Output) { Write-Log "WSL resize output: $($wsl.Output)" -Level "ERROR" }
        throw "wsl --manage $Distro --resize $size failed (exit $($wsl.ExitCode))"
    }
    if ($wsl.Output) { Write-Log "WSL resize output: $($wsl.Output)" }
}

# Idempotently set key=value in ~/.wslconfig under [wsl2], creating the
# file/section when missing. Changes only take effect after
# 'wsl --shutdown'.
function Set-WslConfigValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $path = Join-Path $env:USERPROFILE ".wslconfig"
    $config = ''
    if (Test-Path $path) { $config = Get-Content $path -Raw }
    if ($null -eq $config) { $config = '' }
    $newline = $config.Contains("`r`n") ? "`r`n" : "`n"
    $lines = $config.Length ? @($config -split '\r?\n') : @()
    if ($lines.Count -and $lines[-1] -eq '') {
        $lines = @($lines | Select-Object -SkipLast 1)
    }
    $updatedLines = @()
    $inWsl2 = $false
    $foundWsl2 = $false
    $keyWritten = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:[#;].*)?$') {
            if ($inWsl2 -and -not $keyWritten) {
                $updatedLines += "$Key=$Value"
                $keyWritten = $true
            }
            $inWsl2 = $Matches[1].Trim() -eq 'wsl2'
            if ($inWsl2) { $foundWsl2 = $true }
        } elseif ($line -match '^\s*([^=\s]+)\s*=') {
            if ($Matches[1] -eq $Key) {
                if ($inWsl2 -and -not $keyWritten) {
                    $updatedLines += "$Key=$Value"
                    $keyWritten = $true
                }
                continue
            }
        }
        $updatedLines += $line
    }
    if (-not $foundWsl2) { $updatedLines += '[wsl2]' }
    if (-not $keyWritten) { $updatedLines += "$Key=$Value" }
    Set-Content $path (($updatedLines -join $newline) + $newline) -Encoding UTF8 -NoNewline
    Write-Log "$Key=$Value in ~/.wslconfig [wsl2] (applies after 'wsl --shutdown')"
}
