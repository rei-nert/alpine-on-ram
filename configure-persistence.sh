#!/bin/sh
#
# configure-persistence.sh
# Configures encrypted data mount, LBU, APK cache, and desktop after setup-alpine
#
# Run this AFTER setup-alpine completes (while still in the live system, before reboot)
#
set -eu

usage() {
    cat <<'EOF'
Configure Persistence for Alpine Diskless + ext4 + Encrypted Btrfs

Usage: ./configure-persistence.sh <boot-partition> <ext4-partition> <data-partition> <username>

Arguments:
  boot-partition   Boot partition (e.g., /dev/mmcblk0p1)
  ext4-partition   ext4 data partition (e.g., /dev/mmcblk0p2)
  data-partition   Encrypted data partition (e.g., /dev/mmcblk0p3)
  username         Your user account name

This script configures:
  - Encrypted Btrfs auto-mount at boot (dmcrypt)
  - LBU backup to boot partition
  - APK cache on boot partition
  - Sway + greetd desktop
  - SD card optimizations (noatime, zram, fstrim, tmpfs)
  - User home on encrypted partition

Run AFTER setup-alpine, BEFORE first reboot.
EOF
    exit 1
}

BOOT_PART="${1:-}"
EXT4_PART="${2:-}"
DATA_PART="${3:-}"
USERNAME="${4:-}"

if [ -z "$BOOT_PART" ] || [ -z "$EXT4_PART" ] || [ -z "$DATA_PART" ] || [ -z "$USERNAME" ]; then
    usage
fi

if [ ! -b "$BOOT_PART" ] || [ ! -b "$EXT4_PART" ] || [ ! -b "$DATA_PART" ]; then
    echo "Error: Partitions not found"
    exit 1
fi

# No key file needed - password-based LUKS encryption
# Password will be prompted at boot via dmcrypt auto-unlock configuration

MOUNT_POINT="/media/usb"

echo ">>> Mounting boot partition..."
mkdir -p "$MOUNT_POINT"
mount "$BOOT_PART" "$MOUNT_POINT"

echo ">>> Getting partition UUIDs..."
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
EXT4_UUID=$(blkid -s UUID -o value "$EXT4_PART")

echo ">>> Updating fstab..."
cat > "$MOUNT_POINT/fstab" <<EOF
# Boot partition (LBU + APK cache)
UUID=$BOOT_UUID  $MOUNT_POINT  vfat  defaults,noatime 0 0

# ext4 system config partition
UUID=$EXT4_UUID  $MOUNT_POINT/ext4  ext4  defaults,noatime 0 0

# Encrypted Btrfs data partition
/dev/mapper/alpine_data  /mnt/data  btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd  0 0

# Subvolume mounts
/mnt/data/@home          /home      btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@home  0 0
/mnt/data/@var_log       /var/log   btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@var_log  0 0
/mnt/data/@opt           /opt       btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@opt  0 0
/mnt/data/@root          /root      btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@root  0 0
/mnt/data/@var_lib_flatpak /var/lib/flatpak btrfs defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@var_lib_flatpak 0 0

# RAM-backed tmpfs for write-heavy directories
tmpfs  /tmp         tmpfs  defaults,noatime,nosuid,nodev,size=512M  0 0
tmpfs  /var/tmp     tmpfs  defaults,noatime,nosuid,nodev,size=256M  0 0
tmpfs  /var/cache   tmpfs  defaults,noatime,nosuid,nodev,size=256M  0 0
EOF

echo ">>> Configuring dmcrypt auto-unlock..."
rc-update add dmcrypt boot
mkdir -p "$MOUNT_POINT/conf.d"
cat >> "$MOUNT_POINT/conf.d/dmcrypt" <<EOF

target=alpine_data
source='UUID='${DATA_PART##*/}
EOF



echo ">>> Creating mount points..."
mkdir -p "$MOUNT_POINT/mnt/data" "$MOUNT_POINT/home" "$MOUNT_POINT/var/log" "$MOUNT_POINT/opt" "$MOUNT_POINT/root" "$MOUNT_POINT/var/lib/flatpak"

echo ">>> Configuring LBU..."
sed -i 's%^# *LBU_BACKUPDIR=.*%LBU_BACKUPDIR=/media/usb%' "$MOUNT_POINT/etc/lbu/lbu.conf"
# Exclude data mounts from LBU to prevent loops
echo "/mnt/data" >> "$MOUNT_POINT/etc/lbu/lbu.exclude" 2>/dev/null || true
echo "/media/usb" >> "$MOUNT_POINT/etc/lbu/lbu.exclude" 2>/dev/null || true
# Use lbu exclude command if available
if command -v lbu >/dev/null 2>&1; then
    lbu exclude /mnt/data 2>/dev/null || true
    lbu exclude /media/usb 2>/dev/null || true
fi

echo ">>> Enabling community repository..."
sed -i '/community/s/^#//' "$MOUNT_POINT/etc/apk/repositories"

echo ">>> Installing desktop packages..."
# This runs in the live system, so packages install to RAM
# They will be cached to APK cache on commit
setup-wayland-base
apk add \
    sway swaybg swayidle swaylockd sway-doc \
    foot \
    greetd greetd-gtkgreet \
    elogind polkit-elogind \
    dbus \
    font-dejavu font-noto font-noto-emoji \
    grim wl-clipboard wmenu \
    xwayland \
    brightnessctl \
    networkmanager networkmanager-elogind \
    pipewire pipewire-pulse wireplumber \
    udisks2 \
    btrfs-progs \
    fstrim \
    zram-init \
    cronie \
    vim \
    neovim \
    vis \
    tmux \
    git \
    firefox \
    doas

echo ">>> Enabling services..."
rc-update add dbus
rc-update add elogind
rc-update add polkit
rc-update add networkmanager
rc-update add greetd
rc-update add cronie
rc-update add zram-init boot

echo ">>> Configuring greetd for Sway..."
cat > "$MOUNT_POINT/etc/greetd/config.toml" <<EOF
[terminal]
vt = 1
switch = true

[default_session]
command = "cage -s -m extend -- gtkgreet"
user = "greetd"

[initial_session]
command = "dbus-run-session sway"
user = "$USERNAME"
EOF

cat > "$MOUNT_POINT/etc/conf.d/greetd" <<EOF
cfgfile="/etc/greetd/config.toml"
rc_need="elogind seatd"
EOF

addgroup greetd video 2>/dev/null || true

cat > "$MOUNT_POINT/etc/greetd/environments" <<EOF
sway
foot
bash
EOF

echo ">>> Configuring zram swap..."
cat > "$MOUNT_POINT/etc/conf.d/zram-init" <<EOF
COMP_ALGO=zstd
MEM_LIMIT_PERCENT=50
MAX_SIZE=4096
EOF

echo ">>> Setting up weekly fstrim cron..."
mkdir -p "$MOUNT_POINT/etc/periodic/weekly"
cat > "$MOUNT_POINT/etc/periodic/weekly/fstrim" <<'EOF'
#!/bin/sh
# Weekly TRIM for Btrfs on SD card
fstrim -v /mnt/data 2>/dev/null || true
fstrim -v /home 2>/dev/null || true
fstrim -v /var/log 2>/dev/null || true
fstrim -v /opt 2>/dev/null || true
fstrim -v /root 2>/dev/null || true
fstrim -v /var/lib/flatpak 2>/dev/null || true
EOF
chmod +x "$MOUNT_POINT/etc/periodic/weekly/fstrim"

echo ">>> Setting up user home on encrypted partition..."
# The home directory will be created on first boot via local.d
mkdir -p "$MOUNT_POINT/etc/local.d"
cat > "$MOUNT_POINT/etc/local.d/00-user-home.start" <<EOF
#!/bin/sh
# Create user home directory on encrypted partition at boot
install -d -o $USERNAME -g $USERNAME -m 700 /home/$USERNAME
chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF
chmod +x "$MOUNT_POINT/etc/local.d/00-user-home.start"
rc-update add local

echo ">>> Copying sway config to user home (will persist on encrypted partition)..."
mkdir -p "$MOUNT_POINT/home/$USERNAME/.config/sway"
if [ -f /etc/sway/config ]; then
    cp /etc/sway/config "$MOUNT_POINT/home/$USERNAME/.config/sway/config"
else
    # Create minimal sway config
    cat > "$MOUNT_POINT/home/$USERNAME/.config/sway/config" <<'SWAYEOF'
# Minimal Sway config
include /etc/sway/config.d/*

# Your custom keybindings here
# bindsym Mod4+Enter exec foot
# bindsym Mod4+d exec wmenu-run
SWAYEOF
fi

# Get UID/GID of user
USER_UID=$(id -u "$USERNAME" 2>/dev/null || echo 1000)
USER_GID=$(id -g "$USERNAME" 2>/dev/null || echo 1000)
chown -R "$USER_UID:$USER_GID" "$MOUNT_POINT/home/$USERNAME"

echo ">>> Updating kernel (creates modloop)..."
update-kernel "$MOUNT_POINT/boot"

echo ">>> Committing all changes..."
lbu commit

echo ""
echo "============================================"
echo "  Persistence configuration complete!"
echo "============================================"
echo ""
echo "Next: Reboot into your new Alpine system"
echo "  reboot"
echo ""
echo "After reboot:"
echo "  - System runs from RAM"
echo "  - Encrypted data auto-mounted at /home, /var/log, /opt"
echo "  - Run 'lbu commit' after any package/config changes"
echo "  - Run 'update-kernel /media/usb/boot' after kernel updates"