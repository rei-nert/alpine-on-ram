#!/bin/sh
#
# alpine-sdcard-setup.sh
# Automates the initial SD card partitioning and formatting for Alpine diskless + ext4 + encrypted Btrfs
# LUKS encryption uses password (not key file)
#
# Usage: ./alpine-sdcard-setup.sh <device> [boot-size-gb] [ext4-size-gb]
# Example: ./alpine-sdcard-setup.sh /dev/mmcblk0 2 10
#
set -eu

usage() {
    cat <<'EOF'
Alpine Linux SD Card Setup - Diskless Mode with ext4 + Encrypted Btrfs
LUKS encryption uses password (not key file)

Usage: ./alpine-sdcard-setup.sh <device> [boot-size-gb] [ext4-size-gb]

Arguments:
  device           Target SD card device (e.g., /dev/mmcblk0, /dev/sdb)
  boot-size-gb     Boot partition size in GB (default: 2)
  ext4-size-gb     ext4 partition size in GB (default: 10)

This script will:
  1. Wipe the device and create GPT partition table
  2. Create FAT32 boot partition
  3. Create ext4 system config partition
  4. Create LUKS2 encrypted data partition (password-based, no key file)
  5. Create Btrfs subvolumes (@home, @var_log, @opt, @root)
  6. Prompt for encryption password

WARNING: THIS DESTROYS ALL DATA ON THE TARGET DEVICE!

Requirements: sgdisk, cryptsetup, mkfs.vfat, mkfs.ext4, mkfs.btrfs, btrfs, parted
EOF
    exit 1
}

DEVICE="${1:-}"
BOOT_SIZE_GB="${2:-2}"
EXT4_SIZE_GB="${3:-10}"

if [ -z "$DEVICE" ] || [ ! -b "$DEVICE" ]; then
    echo "Error: Device '$DEVICE' not found or not a block device"
    usage
fi

# Confirm destruction
echo "============================================"
echo "  WARNING: This will DESTROY all data on:"
echo "  $DEVICE"
echo "============================================"
printf "Type 'YES' to continue: "
read -r confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# Check required tools
for cmd in sgdisk cryptsetup mkfs.vfat mkfs.ext4 mkfs.btrfs btrfs parted; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' not found"
        exit 1
    fi
done

echo ">>> Installing required packages..."
apk add --quiet sgdisk cryptsetup e2fsprogs dosfstools 2>/dev/null || true

echo ">>> Wiping device and creating partition table..."
sgdisk --zap-all "$DEVICE"
# Partition 1: Boot (FAT32)
sgdisk -n 1:0:+${BOOT_SIZE_GB}G -t 1:ef00 -c 1:"ALPINE_BOOT" "$DEVICE"
# Partition 2: ext4 system configs
sgdisk -n 2:0:+${EXT4_SIZE_GB}G -t 2:8300 -c 2:"ALPINE_SYSTEM" "$DEVICE"
# Partition 3: LUKS2 + Btrfs data
sgdisk -n 3:0:0 -t 3:8304 -c 3:"ALPINE_DATA" "$DEVICE"
partprobe "$DEVICE" 2>/dev/null || mdev -s
sleep 2

BOOT_PART="${DEVICE}p1"
EXT4_PART="${DEVICE}p2"
DATA_PART="${DEVICE}p3"

# Handle nvme/mmcblk naming
if [ ! -b "$BOOT_PART" ]; then
    BOOT_PART="${DEVICE}1"
    EXT4_PART="${DEVICE}2"
    DATA_PART="${DEVICE}3"
fi

echo ">>> Formatting boot partition (FAT32)..."
mkfs.vfat -F32 -n ALPINE_BOOT "$BOOT_PART"
modprobe vfat 2>/dev/null || true

echo ">>> Formatting ext4 system config partition..."
mkfs.ext4 -L ALPINE_SYSTEM "$EXT4_PART"

echo ">>> Creating LUKS2 encrypted container on data partition (password-based, no key file)..."
cryptsetup luksFormat \
   --type=luks2 \
   "$DATA_PART"

echo ">>> Opening LUKS container to verify..."
cryptsetup luksOpen "$DATA_PART" alpine_data

echo ">>> Creating Btrfs filesystem with SSD optimizations..."
mkfs.btrfs -L ALPINE_DATA /dev/mapper/alpine_data

echo ">>> Creating Btrfs subvolumes..."
mount /dev/mapper/alpine_data /mnt
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@var_lib_flatpak
umount /mnt

echo ">>> Closing LUKS container..."
cryptsetup luksClose alpine_data

echo ""
echo "============================================"
echo "  SD Card partitioning complete!"
echo "============================================"
echo ""

echo "Partitions:"
echo "  $BOOT_PART  - FAT32 (${BOOT_SIZE_GB}GB) - Boot + LBU + APK cache"
echo "  $EXT4_PART  - ext4 (${EXT4_SIZE_GB}GB) - System configs + APK cache"
echo "  $DATA_PART  - LUKS2 (password-based) - Encrypted user data"
echo ""

echo "Next steps:"
echo "  1. Mount boot partition: mount $BOOT_PART /media/usb"
echo "  2. Run setup-bootable from Alpine ISO"
echo "  3. Run setup-alpine (disk: none, config: /media/usb)"
echo "  4. Run ./configure-persistence.sh to finish setup"

echo ""
echo "IMPORTANT: You will need to enter the LUKS password each time you boot"
echo "  to unlock the data partition. Store this password securely."