#!/bin/sh
# Small per-distro cleanup: rotated dmesg files + the caches of ALL detected
# package managers. Invoked by cleanup-distro.ps1 as root, piped via stdin:
#     wsl -d <distro> -u root -e sh -

# Rotated dmesg logs (rare, but large when present)
rm -f /var/log/dmesg.*.gz /var/log/dmesg.[0-9]

# Force log rotation so live logs (syslog, kern.log, ...) shrink before
# compaction. On WSL the daily logrotate timer may not have fired; -f
# rotates unconditionally. Best-effort: never fatal.
if command -v logrotate >/dev/null; then
    logrotate -f /etc/logrotate.conf >/dev/null 2>&1 && echo 'forced log rotation'
fi

# Clean the cache of every installed package manager (both dnf and dnf5 can
# coexist, so each is listed). Per-manager commands differ, hence the case.
clean_cache() {
    case $1 in
        apt-get) apt-get -y clean && rm -rf /var/lib/apt/lists/* ;;
        dnf5|dnf|yum) "$1" clean all ;;
        apk) apk cache clean ;;
        pacman) rm -rf /var/cache/pacman/pkg ;;
        zypper) zypper clean --all ;;
    esac
}
cleaned=no
failed=no
for pm in apt-get dnf5 dnf yum apk pacman zypper; do
    command -v "$pm" >/dev/null || continue
    if clean_cache "$pm"; then
        echo "cleaned package cache via $pm"
        cleaned=yes
    else
        failed=yes
    fi
done
[ "$cleaned" = yes ] || echo 'no supported package manager detected'
[ "$failed" = no ]
