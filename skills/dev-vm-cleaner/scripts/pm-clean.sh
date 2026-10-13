#!/bin/sh
# Per-distro cleanup: rotated dmesg files, system package caches, and
# developer caches for root and normal users. Invoked as root via stdin:
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

developer_cleanup=$(cat <<'SH'
developer_failed=no
cache_user=$(id -un)
echo "Developer cache cleanup for $cache_user (HOME=$HOME)"
export COREPACK_ENABLE_NETWORK=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

try_developer_cache() {
    tool_path=$(command -v "$1") || { echo "skipped $1: not on PATH"; return 1; }
    case "$tool_path" in
        /mnt/*|*.exe|*.cmd|*.bat) echo "skipped $1: Windows-mounted tool"; return 1 ;;
    esac
    [ -f "$tool_path" ] && [ -x "$tool_path" ] || { echo "skipped $1: not an executable file"; return 1; }
    case "$1" in
        python3|python) "$1" -m pip --version >/dev/null 2>&1 || { echo "skipped $1: pip not installed"; return 1; } ;;
    esac
    if "$@"; then
        echo "cleaned developer cache via $1 for $cache_user"
    else
        cleanup_exit=$?
        echo "WARNING: $1 cache cleanup failed for $cache_user (exit $cleanup_exit)" >&2
        developer_failed=yes
    fi
    return 0
}

try_developer_cache dotnet nuget locals all --clear
try_developer_cache npm cache clean --force
try_developer_cache pnpm store prune
try_developer_cache yarn cache clean
try_developer_cache composer clear-cache
try_developer_cache pip3 cache purge || try_developer_cache pip cache purge ||
    try_developer_cache python3 -m pip cache purge || try_developer_cache python -m pip cache purge
try_developer_cache uv cache clean
try_developer_cache go clean -cache -testcache -modcache
[ "$developer_failed" = no ]
SH
)

sh -c "$developer_cleanup" </dev/null || failed=yes
if [ "$(id -u)" -eq 0 ]; then
    user_entries=$(getent passwd 2>/dev/null || cat /etc/passwd)
    while IFS=: read -r cache_user password_field user_uid group_id user_info user_home user_shell; do
        { [ "$user_uid" -ge 1000 ] && [ "$user_uid" -lt 65534 ]; } 2>/dev/null || continue
        case "$user_shell" in
            */nologin|*/false|'') continue ;;
        esac
        [ -d "$user_home" ] || continue
        su - "$cache_user" -s /bin/sh -c "$developer_cleanup" </dev/null || failed=yes
    done <<EOF
$user_entries
EOF
fi
[ "$failed" = no ]
