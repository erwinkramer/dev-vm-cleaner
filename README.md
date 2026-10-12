# Dev VM Cleaner

Agent plugin for unattended host cache and WSL distro cleanup: package manager cache, Podman/Docker Desktop resources, systemd journal, VHDX compaction, and a disk size cap. No admin required.

Cleanup runs through the `dev-vm-cleaner` skill (`skills/dev-vm-cleaner/SKILL.md`), which probes the WSL CLI to pick the right distro and parameters. The scripts are not meant to be invoked directly.

## Layout

- `skills/dev-vm-cleaner/SKILL.md` — how the agent uses the plugin
- `skills/dev-vm-cleaner/scripts/cleanup-host.ps1` — clears configured host-user caches once
- `skills/dev-vm-cleaner/scripts/` — the remaining distro cleanup scripts; each script's header comments describe what it does
- `skills/dev-vm-cleaner/logs/` — cleanup logs

## Requirements

- WSL >= 3.0.0 (`wsl --manage --compact`/`--resize`; checked at start, fails fast)
- PowerShell 7.6+ (`pwsh`), also runs under ConstrainedLanguage mode

## Development

Requirements for developing.

If not on a CLM machine, configure `notepad $PROFILE` with:

```powershell
$ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
```

## Speedrun

Run the follow to one-shot cleanup without using the skill, assuming the distro names are `Ubuntu` and `podman-machine-default`:

```powershell
./skills/dev-vm-cleaner/scripts/cleanup-host.ps1 && `
./skills/dev-vm-cleaner/scripts/cleanup-distro.ps1 -Distro Ubuntu && `
./skills/dev-vm-cleaner/scripts/cleanup-distro.ps1 -Distro podman-machine-default
```
