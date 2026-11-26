# Alpine Linux Desktop on SD Card - Diskless Mode with ext4 + Encrypted Btrfs

## Overview

This setup creates a daily-driver Alpine Linux workstation on a 128GB SD card with:

- **Partition 1 (FAT32, ~2GB)**: Bootable, contains kernel/initramfs/modloop, LBU backups
- **Partition 2 (ext4, ~10GB)**: System configs + APK cache partition
- **Partition 3 (LUKS2 + Btrfs, ~116GB)**: Encrypted user data (/home, /var/log, /opt, etc.)
- **System runs entirely from RAM** (diskless mode)
- **Writes to SD card only on `lbu commit`**
- **Sway + greetd** (Wayland-native, lightweight)
- **SD card optimizations**: noatime, discard=async, fstrim cron, zram swap

## Partition Layout (128GB SD Card)

```text
/dev/mmcblk0 (or /dev/sdX)
├── /dev/mmcblk0p1  2GB   FAT32     Boot + LBU + APK cache (LABEL=ALPINE_BOOT)
├── /dev/mmcblk0p2  10GB  ext4      System configs + APK cache (LABEL=ALPINE_SYSTEM)
└── /dev/mmcblk0p3  116GB LUKS2+Btrfs Encrypted user data (LABEL=ALPINE_DATA)
```

## Prerequisites

- 128GB SD card (A2/V30 rated recommended)
- Alpine Linux Extended ISO (for x86_64 or aarch64)
- Target machine with UEFI boot (or BIOS with GRUB)
- At least 4GB RAM (8GB+ recommended for desktop use)

## Step 1: Prepare the SD Card

```bash
# Identify your SD card (BE CAREFUL - this wipes the device!)
lsblk
export SDCARD=/dev/mmcblk0  # or /dev/sdX

# Wipe and create GPT partition table
sgdisk --zap-all $SDCARD

# Partition 1: 2GB FAT32 for boot (ESP)
sgdisk -n 1:0:+2G -t 1:ef00 -c 1:"ALPINE_BOOT" $SDCARD

# Partition 2: 10GB ext4 for system configs
sgdisk -n 2:0:+10G -t 2:8300 -c 2:"ALPINE_SYSTEM" $SDCARD

# Partition 3: Rest for encrypted Btrfs
sgdisk -n 3:0:0 -t 3:8304 -c 3:"ALPINE_DATA" $SDCARD

# Reload partition table
partprobe $SDCARD
# or: mdev -s
```

## Step 2: Format Partitions

```bash
# Partition 1: FAT32 (ESP)
mkfs.vfat -F32 -n ALPINE_BOOT ${SDCARD}p1

# Partition 2: ext4 (system configs + APK cache)
mkfs.ext4 -L ALPINE_SYSTEM ${SDCARD}p2

# Partition 3: LUKS2 + Btrfs




# Create LUKS2 container with minimal PBKDF iterations (key has full entropy)
cryptsetup luksFormat \
   --type=luks2 \
   --batch-mode \
\
   --pbkdf pbkdf2 \
   --pbkdf-force-iterations 1000 \
   ${SDCARD}p3

# Open the container
cryptsetup luksOpen /dev/mapper/alpine_data
# Enter your LUKS password when prompted

# Create Btrfs filesystem with SSD optimizations
mkfs.btrfs -L ALPINE_DATA /dev/mapper/alpine_data
```

## Step 3: Create Btrfs Subvolumes

```bash
# Mount to create subvolumes
mount /dev/mapper/alpine_data /mnt

# Create subvolumes for persistent directories
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@root  # for /root if desired

# Optional: subvolume for flatpak/app data
btrfs subvolume create /mnt/@var_lib_flatpak

umount /mnt
```

## Step 4: Boot Alpine Installer & Install to SD Card

1. Boot Alpine Extended ISO
2. Login as root
3. Setup network: `setup-interfaces` (or use existing connection)
4. Install required packages:
   ```bash
   apk add sfdisk blkid btrfs-progs cryptsetup sgdisk
   ```
5. Mount the ISO and copy to SD card boot partition:
   ```bash
   # Assuming ISO is mounted at /media/cdrom
   mount ${SDCARD}p1 /media/usb
   setup-bootable -v /media/cdrom /media/usb
   ```

6. Update fstab on the boot partition:
   ```bash
   UUID=$(blkid -s UUID -o value ${SDCARD}p1)
   cat > /media/usb/fstab <<EOF
   UUID=$UUID  /media/usb  vfat  defaults,noatime 0 0
   EOF
   ```

7. Run `setup-alpine`:
   - Keyboard, hostname, network: configure normally
   - **Disk: `none`** (diskless mode)
   - **Config storage: `/media/usb`** (the boot partition)
   - **APK cache: `/media/usb/cache`**
   - User: create your user (add to `wheel`, `video`, `audio`, `input`, `seat` groups)
   - SSH: enable if desired
   - **Don't reboot yet!**

## Step 5: Configure Persistent ext4 + Encrypted Data Mount

```bash
# Mount the boot partition (if not already)
mount ${SDCARD}p1 /media/usb

# Add ext4 mount to fstab (system configs)
EXT4_UUID=$(blkid -s UUID -o value ${SDCARD}p2)
cat >> /media/usb/fstab <<EOF

# ext4 system config partition
UUID=$EXT4_UUID  /media/usb/ext4  ext4  defaults,noatime 0 0
EOF

# Add encrypted data mount to fstab
DATA_UUID=$(blkid -s UUID -o value ${SDCARD}p3)
cat >> /media/usb/fstab <<EOF

# Encrypted Btrfs data partition
/dev/mapper/alpine_data  /mnt/data  btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd  0 0

# Subvolume mounts
/mnt/data/@home          /home      btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@home  0 0
/mnt/data/@var_log       /var/log   btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@var_log  0 0
/mnt/data/@opt           /opt       btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@opt  0 0
/mnt/data/@root          /root      btrfs  defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@root  0 0
/mnt/data/@var_lib_flatpak /var/lib/flatpak btrfs defaults,noatime,discard=async,space_cache=v2,compress=zstd,subvol=@var_lib_flatpak 0 0
EOF

# Configure dmcrypt to auto-unlock at boot
rc-update add dmcrypt boot
cat >> /media/usb/conf.d/dmcrypt <<EOF

target=alpine_data
source='UUID=$DATA_UUID'

EOF




# Create mount points
mkdir -p /media/usb/mnt/data /media/usb/home /media/usb/var/log /media/usb/opt
```

## Step 6: Configure LBU and APK Cache

```bash
# LBU config - store backups on boot partition
sed -i 's%^# *LBU_BACKUPDIR=.*%LBU_BACKUPDIR=/media/usb%' /media/usb/etc/lbu/lbu.conf

# Exclude the data mount from LBU (prevents infinite loop)
lbu exclude /mnt/data
lbu exclude /media/usb

# APK cache already configured by setup-alpine to /media/usb/cache
# Verify:
cat /media/usb/etc/apk/cache
# Should show: /media/usb/cache
```

## Step 7: Install Desktop Environment (Sway + greetd)

```bash
# Enable community repository
sed -i '/community/s/^#//' /media/usb/etc/apk/repositories
apk update

# Install Wayland base + Sway + greetd + essentials
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
    cronie

# Enable services
rc-update add dbus
rc-update add elogind
rc-update add polkit
rc-update add networkmanager
rc-update add greetd
rc-update add cronie
rc-update add zram-init boot

# Configure greetd for Sway
cat > /media/usb/etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1
switch = true

[default_session]
command = "cage -s -m extend -- gtkgreet"
user = "greetd"

[initial_session]
command = "dbus-run-session sway"
user = "YOUR_USERNAME"
EOF

cat > /media/usb/etc/conf.d/greetd <<'EOF'
cfgfile="/etc/greetd/config.toml"
rc_need="elogind seatd"
EOF

# Add greetd user to video group
addgroup greetd video

# Configure greetd environments
cat > /media/usb/etc/greetd/environments <<'EOF'
sway
foot
bash
EOF

# Copy sway config to user home (will be on encrypted partition)
mkdir -p /media/usb/home/YOUR_USERNAME/.config/sway
cp /etc/sway/config /media/usb/home/YOUR_USERNAME/.config/sway/config
chown -R 1000:1000 /media/usb/home/YOUR_USERNAME  # adjust UID/GID
```

## Step 8: Configure SD Card Optimizations

### fstab optimizations (already applied above):
- `noatime` - disable access time updates
- `discard=async` - async TRIM for Btrfs
- `space_cache=v2` - faster mount
- `compress=zstd` - compression saves writes

### zram swap (no SD card swap):
```bash
# Configure zram
cat > /media/usb/etc/conf.d/zram-init <<'EOF'
# Use zstd compression, size = 50% RAM up to 4GB
COMP_ALGO=zstd
MEM_LIMIT_PERCENT=50
MAX_SIZE=4096
EOF
```

### fstrim cron (weekly TRIM):
```bash
cat > /media/usb/etc/periodic/weekly/fstrim <<'EOF'
#!/bin/sh
# Weekly TRIM for Btrfs on SD card
fstrim -v /mnt/data 2>/dev/null || true
fstrim -v /home 2>/dev/null || true
fstrim -v /var/log 2>/dev/null || true
fstrim -v /opt 2>/dev/null || true
EOF
chmod +x /media/usb/etc/periodic/weekly/fstrim
```

### tmpfs for write-heavy directories:
```bash
cat >> /media/usb/fstab <<'EOF'

# RAM-backed tmpfs for temporary files
tmpfs  /tmp         tmpfs  defaults,noatime,nosuid,nodev,size=512M  0 0
tmpfs  /var/tmp     tmpfs  defaults,noatime,nosuid,nodev,size=256M  0 0
tmpfs  /var/cache   tmpfs  defaults,noatime,nosuid,nodev,size=256M  0 0
EOF
```

### Reduce logging writes:
```bash
cat > /media/usb/etc/syslog.conf <<'EOF'
# Minimal logging to reduce writes
*.*;auth,authpriv.none	   	   -/var/log/messages
auth,authpriv.*	   	   /var/log/auth.log
*.=info;*.=notice;*.=warn;\
  auth,authpriv.none;\
  cron,daemon.none;\
  mail,news.none	   	   -/var/log/info.log
EOF
```

# Or use busybox syslog with -O (circular buffer in RAM)
# Add to /etc/conf.d/syslog: SYSLOGD_OPTS="-O /var/log/messages -s 512 -b 4"

## Step 9: Final Configuration & Commit

```bash
# Set hostname, keymap, timezone if not done
# setup-hostname, setup-keymap, setup-timezone

# Commit all changes to LBU backup
lbu commit

# Verify backup created
ls -la /media/usb/*.apkovl.tar.gz

# Update kernel (creates new modloop)
update-kernel /media/usb/boot

# Reboot and test!
reboot
```

## Step 10: Post-Boot Verification

After reboot into the new system:

```bash
# Verify running from RAM
mount | grep "on / type"
# Should show: tmpfs on / type tmpfs (rw,relatime)

# Verify encrypted data mounted
mount | grep btrfs
# Should show subvolumes mounted at /home, /var/log, /opt

# Verify APK cache works
apk cache download
apk add vim  # test installing a package
lbu commit   # save the new package

# Verify greetd/Sway starts
rc-status | grep greetd

# Test fstrim
fstrim -v /mnt/data
```

## Daily Usage

### Installing new packages:
```bash
apk add <package>
lbu commit      # Saves to SD card boot partition
```

### Updating system:
```bash
apk update
apk upgrade
update-kernel /media/usb/boot  # If kernel updated
lbu commit
```

### Backing up the LBU key (critical!):
```bash
# The LBU backup can be encrypted
lbu encrypt -p your_password  # Creates .apkovl.tar.gz.enc
# Or use: LBU_ENCRYPT=aes-256-cbc lbu commit
```

### Manual fstrim (if needed):
```bash
fstrim -v /mnt/data
fstrim -v /home
fstrim -v /var/log
fstrim -v /opt
```

## Recovery / Backup

### Backup the entire SD card:
```bash
# From another Linux machine
dd if=/dev/mmcblk0 of=alpine-sdcard-backup.img bs=4M status=progress
# Compress: gzip alpine-sdcard-backup.img
```

### Backup just the LBU backup + key:
```bash
# Copy these to safe storage:
# /media/usb/*.apkovl.tar.gz(.enc)

```

### Restore to new SD card:
1. Partition new card same way
2. Format boot partition FAT32
3. Format ext4 partition for system configs
4. Format LUKS2 + Btrfs for data
5. Copy LBU backup and key to boot partition
6. Run `cryptsetup luksOpen /dev/mapper/alpine_data`
7. Mount subvolumes, verify data
8. `lbu commit` to finalize

## Troubleshooting

### Boot fails - "no bootable device":
- Verify ESP partition flag: `sgdisk -p $SDCARD` should show `EF00` on partition 1
- Verify `setup-bootable` ran successfully
- For BIOS: install GRUB: `grub-install --target=i386-pc $SDCARD`

### Encrypted partition doesn't unlock:
- Check password path in `/etc/conf.d/dmcrypt`
- Verify password is set correctly
- Test manually: `cryptsetup luksOpen /dev/mmcblk0p3 alpine_data`

### LBU commit fails / loop:
- Ensure `/mnt/data` and `/media/usb` are in `lbu exclude`
- Check `/etc/apk/protected_paths.d/lbu.list` doesn't include data mount points

### Sway doesn't start:
- Verify user in `video`, `input`, `seat` groups
- Check `rc-status` for `elogind`, `seatd`, `greetd`
- Try `sway` from TTY to see error messages

### SD card wear concerns:
- Monitor with: `smartctl -a /dev/mmcblk0` (if supported)
- Check write amplification: `iostat -dx 5 /dev/mmcblk0`
- Ensure `noatime` on all mounts
- Consider industrial/SLC SD card for heavy use

## Key Files Reference

| File | Purpose |
|------|---------|
| `/media/usb/fstab` | Mount configuration |
| `/media/usb/etc/lbu/lbu.conf` | LBU backup directory |
| `/media/usb/etc/apk/repositories` | Package repositories |
| `/media/usb/etc/apk/cache` | APK cache location |
| `/media/usb/conf.d/dmcrypt` | Auto-unlock config |
| `/media/usb/etc/greetd/config.toml` | Display manager config |
| `/media/usb/etc/conf.d/zram-init` | Zram swap config |
| `/media/usb/etc/periodic/weekly/fstrim` | Weekly TRIM cron |

## Security Notes

- **Boot partition is unencrypted** - anyone with physical access can read LBU backups
- **Encrypt LBU backups**: `lbu encrypt` or set `LBU_ENCRYPT` in lbu.conf
- **Key file on boot partition** - if SD card stolen, data partition can be unlocked
- **For high security**: Use full disk encryption including boot (requires GRUB + LUKS2)

## Performance Tips

1. **Use A2/V30 rated SD card** - better random IOPS
2. **Leave 10-20% free space** - wear leveling needs free blocks
3. **Use zram swap** - zero SD card writes for swap
4. **tmpfs for /tmp, /var/tmp, /var/cache** - RAM for temp files
5. **Btrfs compress=zstd** - reduces physical writes
6. **Weekly fstrim** - maintains performance over time

## License

This guide is provided as-is for educational purposes. Adapt to your specific hardware and threat model.