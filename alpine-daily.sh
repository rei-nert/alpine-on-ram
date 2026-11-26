#!/bin/sh
#
# alpine-daily.sh - Daily operations helper for Alpine diskless SD card
#
# Usage: alpine-daily.sh <command> [args]
#
# Commands:
#   commit              - Save changes (lbu commit + apk cache sync)
#   update              - Update system (apk upgrade + kernel + commit)
#   install <pkg>       - Install package and commit
#   remove <pkg>        - Remove package and commit
#   fstrim              - Run manual TRIM on encrypted partition
#   backup              - Backup LBU backup and key to external location
#   status              - Show system status (RAM usage, mounts, etc.)
#
set -eu

MOUNT_POINT="/media/usb"
KEY_FILE="$MOUNT_POINT/alpine_data_key.bin"

usage() {
    cat <<'EOF'
Alpine Daily Operations Helper

Usage: alpine-daily.sh <command> [args]

Commands:
  commit              Save all changes to SD card (lbu commit)
  update              Full system update (apk upgrade + kernel + commit)
  install <pkg...>    Install package(s) and commit
  remove <pkg...>     Remove package(s) and commit
  fstrim              Run manual TRIM on all Btrfs mounts
  backup <dir>        Backup LBU backup + encryption key to directory
  status              Show system status
  help                Show this help
EOF
}

cmd_commit() {
    echo ">>> Committing changes..."
    lbu commit
    echo ">>> Syncing APK cache..."
    apk cache download
    apk cache purge
    echo "Done."
}

cmd_update() {
    echo ">>> Updating package index..."
    apk update
    echo ">>> Upgrading packages..."
    apk upgrade
    echo ">>> Checking for kernel update..."
    if apk info -e linux-lts 2>/dev/null | grep -q "linux-lts"; then
        echo ">>> Updating kernel..."
        update-kernel "$MOUNT_POINT/boot"
    fi
    cmd_commit
}

cmd_install() {
    if [ $# -eq 0 ]; then
        echo "Error: No package specified"
        exit 1
    fi
    echo ">>> Installing: $*"
    apk add "$@"
    cmd_commit
}

cmd_remove() {
    if [ $# -eq 0 ]; then
        echo "Error: No package specified"
        exit 1
    fi
    echo ">>> Removing: $*"
    apk del "$@"
    cmd_commit
}

cmd_fstrim() {
    echo ">>> Running TRIM on Btrfs mounts..."
    for mount in /mnt/data /home /var/log /opt /root /var/lib/flatpak; do
        if mountpoint -q "$mount" 2>/dev/null; then
            echo "  Trimming $mount..."
            fstrim -v "$mount" || true
        fi
    done
    echo "Done."
}

cmd_backup() {
    DEST="${1:-}"
    if [ -z "$DEST" ]; then
        echo "Error: Backup destination directory required"
        exit 1
    fi
    if [ ! -d "$DEST" ]; then
        echo "Error: Destination not a directory: $DEST"
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    echo ">>> Backing up to $DEST/alpine-backup-$TIMESTAMP/"

    # Backup LBU overlays
    cp -v "$MOUNT_POINT"/*.apkovl.tar.gz* "$DEST/alpine-backup-$TIMESTAMP/" 2>/dev/null || true

    # Backup encryption key
    cp -v "$KEY_FILE" "$DEST/alpine-backup-$TIMESTAMP/" 2>/dev/null || true

    # Backup fstab and key configs
    cp -v "$MOUNT_POINT/fstab" "$DEST/alpine-backup-$TIMESTAMP/" 2>/dev/null || true
    cp -rv "$MOUNT_POINT/etc/lbu" "$DEST/alpine-backup-$TIMESTAMP/" 2>/dev/null || true
    cp -rv "$MOUNT_POINT/etc/apk" "$DEST/alpine-backup-$TIMESTAMP/" 2>/dev/null || true
    cp -rv "$MOUNT_POINT/conf.d/dmcrypt" "$DEST/alpine-backup-$TIMESTAMP/" 2>/dev/null || true

    echo "Backup complete: $DEST/alpine-backup-$TIMESTAMP/"
}

cmd_status() {
    echo "=== Alpine Diskless Status ==="
    echo ""
    echo "--- Memory ---"
    free -h
    echo ""
    echo "--- Root FS (RAM) ---"
    df -h /
    echo ""
    echo "--- Boot Partition ---"
    if mountpoint -q "$MOUNT_POINT"; then
        df -h "$MOUNT_POINT"
        echo "LBU backups:"
        ls -lh "$MOUNT_POINT"/*.apkovl.tar.gz* 2>/dev/null || echo "  None"
    else
        echo "  Not mounted"
    fi
    echo ""
    echo "--- Encrypted Data Partition ---"
    if [ -b /dev/mapper/alpine_data ]; then
        echo "  LUKS: OPEN"
        for subvol in /mnt/data /home /var/log /opt /root /var/lib/flatpak; do
            if mountpoint -q "$subvol" 2>/dev/null; then
                df -h "$subvol" | tail -1 | awk '{print "  " $6 " used / " $2 " (" $5 ")"}'
            fi
        done
    else
        echo "  LUKS: CLOSED"
    fi
    echo ""
    echo "--- Zram Swap ---"
    if [ -f /proc/swaps ]; then
        cat /proc/swaps
    fi
    echo ""
    echo "--- Services ---"
    rc-status --servicelist | grep -E '(greetd|elogind|networkmanager|dbus|polkit|cronie|zram)' | sort
}

case "${1:-help}" in
    commit)     shift; cmd_commit "$@" ;;&
    update)     shift; cmd_update "$@" ;;&
    install)    shift; cmd_install "$@" ;;&
    remove)     shift; cmd_remove "$@" ;;&
    fstrim)     shift; cmd_fstrim "$@" ;;&
    backup)     shift; cmd_backup "$@" ;;&
    status)     shift; cmd_status "$@" ;;&
    help|--help|-h) usage ;;&
    *) echo "Unknown command: $1"; usage; exit 1 ;;
esac