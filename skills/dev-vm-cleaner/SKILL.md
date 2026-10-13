---
name: dev-vm-cleaner
description: Safely reclaim disk space on Windows by cleaning host caches and selected WSL distros, pruning Podman or Docker data, and compacting or capping distro VHDX files. Use when asked to clean WSL, reduce a WSL distro's disk size, reclaim Podman/Docker storage, or run the dev-vm-cleaner scripts; includes verification and optional Kubernetes image-GC follow-up.
compatibility: Windows with WSL >= 3.0.0 and PowerShell 7.6+ (pwsh), including ConstrainedLanguage mode. No admin required.
---

# Development Environment Cleanup

The scripts in `scripts/` clean host-user caches once, then selected WSL distros: package manager and developer-tool caches (root and normal users), logs, journals, and unused container data. They compact and cap distro disks and set `defaultVhdSize` for new distros in `.wslconfig`. Later builds may need to download dependencies again.

## 1. Probe first — never guess

```powershell
wsl --version   # needs >= 3.0.0; if older, warn the user to update WSL
wsl -l -v       # exact distro names + state
```

If the user did not name a distro, list them and ask. If none applies, tell the user there is nothing to clean.

## 2. Clean the host once

Run this once for the host user, not once per distro. Missing tools are skipped quietly. Locked NuGet files are reported as warnings while other cache locations continue. Corepack will not download pnpm for cleanup; if its local executable cannot run, pnpm is skipped with a warning.

```powershell
pwsh -NoProfile -File <skill-dir>/scripts/cleanup-host.ps1
```

## 3. Run — one plain command per distro, never in parallel

```powershell
pwsh -NoProfile -File <skill-dir>/scripts/cleanup-distro.ps1 -Distro <name> [-MaxDiskSize <size>]
```

- One `pwsh -File` line per distro, run sequentially. Do not wrap in loops, script blocks, or helper functions — plain sequential lines only (the script stops the distro, so concurrent runs are unsafe).
- `-Distro`: name exactly as `wsl -l -v` shows.
- `-MaxDiskSize`: integer + B/M/MB/G/GB/T/TB, no decimals (`25GB` ok, `2.5GB` rejected). Keep it >= real usage (shrinking below usage is refused).

Defaults per distro (applied automatically by the script when `-MaxDiskSize` is not given; override only when the user asks):

| Distro | -MaxDiskSize |
|---|---|
| `podman-machine-default` | 10GB |
| `docker-desktop` | 20GB |
| any other (e.g. `Ubuntu`) | 40GB |

For newly created distros the script always writes a fixed `defaultVhdSize=40GB` to `~/.wslconfig` (independent of `-MaxDiskSize`).

Never enable sparse (`wsl --manage <distro> --set-sparse true`, or `sparseVhd` in `.wslconfig` for new distros). It converts a fixed VHD to a dynamic (sparse) VHDX so the host can reclaim unused space, but it changes nothing the guest sees (`df` still reports the VHDX maximum), reclaims nothing by itself, and — on WSL 3.0.1.0 — locks the disk afterwards: both `--resize` and `--compact` are then refused (`E_VIRTUAL_DISK_LIMITATION`, "must not be sparse"), so the `-MaxDiskSize` cap can no longer be applied in either direction (resize fails silently, sometimes after printing "completed successfully" — verify by measuring, never trust exit codes). It is gated behind `--allow-unsafe` (experimental, "potential data corruption" warning). Reversible: `--set-sparse false` restores fixed (full max re-allocated) and `--resize` works again; install-time dynamic VHDX files are resizable — only fixed→sparse conversions are locked out.

The script auto-detects Podman, Docker Desktop, and reachable in-distro Docker. In-distro Docker is pinned to its `default` context; Docker Desktop is pruned through its own Windows-side context.


## 4. Verify

- Host cleanup exit code must be `0`; on non-zero, check `logs/host_cleanup.log`.
- Distro cleanup exit code must be `0`; on non-zero, the last `ERROR:` line in `logs/distro_cleanup.log` has the cause.
- Report the `VHDX size before/after` and `Space saved` lines.
- resize2fs `Nothing to do!` means the cap was already applied — success, not an error.

## 5. Follow up

- Suggest checking kubernetes setup in the wsl distro's (if any), then suggest enabling [garbage collection for unused container images](https://kubernetes.io/docs/concepts/architecture/garbage-collection/#image-maximum-age-gc) to be configured in your kubernetes GitOps repo. Set the `imageMaximumGCAge` pretty low, like `15m`, so on dev machines it always runs at least a few times on a workday. For `k0s`, that would be the following `k0s.yaml`:

```yaml
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  telemetry:
    enabled: false
  workerProfiles:
  - name: default
    values:
      imageMaximumGCAge: "15m"
```

File has to be placed in the right dir, example for `k0s`: `mkdir -p /etc/k0s && cp k0s.yaml /etc/k0s/k0s.yaml`. Worker-profile changes may need a second (`k0s`) restart if the kubelet still reports the old value via `/configz`. Suggest to implement this in their GitOps repo, ask where it's checked-out on the dev vm and check if there is already a ClusterConfig configured.
