#!/bin/sh
#
# alpine-recovery.sh - Disaster recovery for Alpine SD card
#
# Usage: alpine-recovery.sh <command> [args]
#
# Commands:
#   unlock <data-part> <key-file>  - Manually unlock encrypted partition
#   mount-data <data-part> <key>   - Unlock and mount all subvolumes
#   restore-lbu <backup-file>      - Restore LBU backup to boot partition
#   chroot-boot <boot-part>        - Chroot into boot partition for repairs
#   verify                         - Verify all mounts and configs
#
set -eu

usage() {
    cat <<'EOF'
Alpine SD Card Disaster Recovery

Usage: alpine-recovery.sh <command> [args]

Commands:
  unlock <data-part> <key-file>   Unlock encrypted partition manually
  mount-data <data-part> <key>    Unlock and mount all subvolumes
  restore-lbu <backup.apkovl>     Restore LBU backup to boot partition
  chroot-boot <boot-part>         Chroot into boot partition
  verify                          Verify all configs and mounts
  help                            Show this help
EOF
    exit 1
}

cmd_unlock() {
    DATA_PART="${1:-}"
    KEY_FILE="${2:-}"
    if [ -z "$DATA_PART" ] || [ -z "$KEY_FILE" ]; then
        echo "Usage: alpine-recovery.sh unlock <data-part> <key-file>"
        exit 1
    fi
    if [ ! -b "$DATA_PART" ] || [ ! -f "$KEY_FILE" ]; then
        echo "Error: Partition or key file not found"
        exit 1
    fi
    echo ">>> Unlocking $DATA_PART..."
    cryptsetup luks-open --key-file "$KEY_FILE" "$DATA_PART" alpine_data
    echo "Unlocked at /dev/mapper/alpine_data"
}

cmd_mount_data() {
    DATA_PART="${1:-}"
    KEY_FILE="${2:-}"
    if [ -z "$DATA_PART" ] || [ -z "$KEY_FILE" ]; then
        echo "Usage: alpine-recovery.sh mount-data <data-part> <key-file>"
        exit 1
    fi
    cmd_unlock "$DATA_PART" "$KEY_FILE"
    echo ">>> Mounting subvolumes..."
    mount -o noatime,discard=async,space_cache=v2,compress=zstd /dev/mapper/alpine_data /mnt
    for subvol in @home @var_log @opt @root @var_lib_flatpak; do
        mkdir -p "/${subvol#@}"
        mount -o noatime,discard=async,space_cache=v2,compress=zstd,subvol=$subvol /dev/mapper/alpine_data "/${subvol#@}"
        echo "  Mounted $subvol at /${subvol#@}"
    done
    echo "All subvolumes mounted."
}

cmd_restore_lbu() {
    BACKUP_FILE="${1:-}"
    BOOT_PART="${2:-}"
    if [ -z "$BACKUP_FILE" ] || [ -z "$BOOT_PART" ]; then
        echo "Usage: alpine-recovery.sh restore-lbu <backup.apkovl> <boot-part>"
        exit 1
    fi
    if [ ! -f "$BACKUP_FILE" ] || [ ! -b "$BOOT_PART" ]; then
        echo "Error: Backup file or boot partition not found"
        exit 1
    fi
    MOUNT_POINT="/tmp/alpine-boot-recovery"
    mkdir -p "$MOUNT_POINT"
    mount "$BOOT_PART" "$MOUNT_POINT"
    cp "$BACKUP_FILE" "$MOUNT_POINT/"
    # Also restore key if present in backup dir
    KEY_FILE=$(dirname "$BACKUP_FILE")/alpine_data_key.bin
    if [ -f "$KEY_FILE" ]; then
        cp "$KEY_FILE" "$MOUNT_POINT/"
        chmod 400 "$MOUNT_POINT/alpine_data_key.bin"
    fi
    umount "$MOUNT_POINT"
    echo "LBU backup restored to $BOOT_PART"
}

cmd_chroot_boot() {
    BOOT_PART="${1:-}"
    if [ -z "$BOOT_PART" ]; then
        echo "Usage: alpine-recovery.sh chroot-boot <boot-part>"
        exit 1
    fi
    MOUNT_POINT="/tmp/alpine-boot-chroot"
    mkdir -p "$MOUNT_POINT"
    mount "$BOOT_PART" "$MOUNT_POINT"
    echo ">>> Entering chroot at $MOUNT_POINT"
    echo ">>> Run 'exit' to leave"
    chroot "$MOUNT_POINT" /bin/sh
    umount "$MOUNT_POINT"
}

cmd_verify() {
    echo "=== System Verification ==="
    echo ""

    echo "--- Boot Partition ---"
    if mountpoint -q /media/usb; then
        echo "  Mounted: YES"
        echo "  fstab: $(test -f /media/usb/fstab && echo OK || echo MISSING)"
        echo "  LBU config: $(test -f /media/usb/etc/lbu/lbu.conf && echo OK || echo MISSING)"
        echo "  APK cache: $(cat /media/usb/etc/apk/cache 2>/dev/null || echo NOT SET)"
        echo "  dmcrypt config: $(test -f /media/usb/conf.d/dmcrypt && echo OK || echo MISSING)"
        echo "  Encryption key: $(test -f /media/usb/alpine_data_key.bin && echo PRESENT || echo MISSING)"
        echo "  LBU backups: $(ls /media/usb/*.apkovl.tar.gz* 2>/dev/null | wc -l)"
        echo "  Kernel: $(ls /media/usb/boot/vmlinuz* 2>/dev/null | head -1)"
        echo "  Initramfs: $(ls /media/usb/boot/initramfs* 2>/dev/null | head -1)"
        echo "  Modloop: $(ls /media/usb/boot/modloop* 2>/dev/null | head -1)"
    else
        echo "  Mounted: NO"
    fi

    echo ""
    echo "--- Encrypted Data ---"
    if [ -b /dev/mapper/alpine_data ]; then
        echo "  LUKS: OPEN"
        cryptsetup status alpine_data
        for subvol in /mnt/data /home /var/log /opt /root /var/lib/flatpak; do
            if mountpoint -q "$subvol" 2>/dev/null; then
                echo "  $subvol: MOUNTED ($(df -h "$subvol" | tail -1 | awk '{print $3 " / " $2}'))"
            else
                echo "  $subvol: NOT MOUNTED"
            fi
        done
    else
        echo "  LUKS: CLOSED"
    fi

    echo ""
    echo "--- Running System ---"
    echo "  Root FS: $(findmnt -n -o FSTYPE /)"
    echo "  Kernel: $(uname -r)"
    echo "  Uptime: $(uptime -p)"
    echo "  RAM: $(free -h | grep Mem | awk '{print $3 " / " $2}')"
    echo "  Swap: $(free -h | grep Swap | awk '{print $3 " / " $2}')"

    echo ""
    echo "--- Services ---"
    rc-status --servicelist | grep -E '(greetd|elogind|networkmanager|dbus|polkit|cronie|zram|local)' | sort | sed 's/^/  /'

    echo ""
    echo "--- SD Card Health (if supported) ---"
    for dev in /dev/mmcblk0 /dev/sd[a-z]; do
        if [ -b "$dev" ]; then
            smartctl -a "$dev" 2>/dev/null | grep -E '(Wear_Leveling|Media_Wearout|Reallocated_Sector|Total_LBAs_Written)' | head -5 | sed 's/^/  /' || true
        fi
    done
}

case "${1:-help}" in
    unlock)         shift; cmd_unlock "$@" ;;&
    mount-data)     shift; cmd_mount_data "$@" ;;&
    restore-lbu)    shift; cmd_restore_lbu "$@" ;;&
    chroot-boot)    shift; cmd_chroot_boot "$@" ;;&
    verify)         shift; cmd_verify "$@" ;;&
    help|--help|-h) usage ;;&
    *) echo "Unknown command: $1"; usage; exit 1 ;;
esac