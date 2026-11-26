# Alpine SD Card - Quick Reference Card

## Daily Commands

```bash
# Save changes (run after ANY config/package change)
alpine-daily.sh commit
# or: lbu commit && apk cache download && apk cache purge

# Update system
alpine-daily.sh update

# Install package
alpine-daily.sh install vim git htop

# Remove package
alpine-daily.sh remove firefox

# Manual TRIM
alpine-daily.sh fstrim

# Backup LBU + key
alpine-daily.sh backup /mnt/backup-drive

# System status
alpine-daily.sh status
```

## Boot Partition Layout (/media/usb)

```
/media/usb/
├── boot/
│   ├── vmlinuz-lts          # Kernel
│   ├── initramfs-lts        # Initramfs (with modloop)
│   └── modloop-lts          # Kernel modules
├── *.apkovl.tar.gz          # LBU backups (encrypted if configured)

├── fstab                    # Mount configuration
├── conf.d/dmcrypt           # Auto-unlock config
├── etc/
│   ├── lbu/lbu.conf         # LBU settings
│   ├── apk/repositories     # Package repos
│   ├── apk/cache            # APK cache path
│   └── ...
└── cache/                   # APK package cache
  └── ext4 partition (e.g., /media/usb/ext4) - System configs + APK cache
```

## Partition Scheme

The SD card now uses 3 partitions:

| Partition | File System | Purpose |
|-----------|------------|---------|
| `p1` | FAT32 | Boot partition (kernel, initramfs, modloop) |
| `p2` | ext4 | System configs + APK cache partition |
| `p3` | LUKS2 → Btrfs | Encrypted user data partition |

The ext4 partition (`p2`) stores:
- APK cache (survives reboot via LBU commit)
- System configuration files
- LBU backups

The btrfs partition (`p3`, encrypted) stores user data in subvolumes:
- `@home` → `/home`
- `@var_log` → `/var/log`
- `@opt` → `/opt`
- `@root` → `/root`
- `@var_lib_flatpak` → `/var/lib/flatpak`

## Encrypted Data Partition (Btrfs Subvolumes)

```
/dev/mapper/alpine_data (LUKS2)
├── @home          → /home
├── @var_log       → /var/log
├── @opt           → /opt
├── @root          → /root
└── @var_lib_flatpak → /var/lib/flatpak
```

## Key Files to Backup

**CRITICAL - Store offline:**

2. `/media/usb/*.apkovl.tar.gz(.enc)` - System config backups
3. `/media/usb/fstab` - Mount config
4. `/media/usb/conf.d/dmcrypt` - Auto-unlock config

## Troubleshooting

### System won't boot
1. Check BIOS/UEFI boot order (SD card first)
2. Verify ESP partition flag: `sgdisk -p /dev/mmcblk0` → partition 1 should be EF00
3. Try GRUB rescue: `grub-install --target=i386-pc /dev/mmcblk0` (BIOS) or `grub-install --target=x86_64-efi /dev/mmcblk0` (UEFI)

### Encrypted partition won't unlock
```bash
# Manual unlock
cryptsetup luksOpen /dev/mmcblk0p3 alpine_data
# Enter your LUKS password when prompted
# Test key works
cryptsetup luksDump /dev/mmcblk0p3 | grep -A5 "Key Slot"
```

### LBU commit fails / loop
```bash
# Check excludes
lbu exclude -l
# Should show: /mnt/data /media/usb
# Fix:
lbu exclude /mnt/data
lbu exclude /media/usb
```

### Sway/greetd not starting
```bash
# Check services
rc-status | grep -E 'greetd|elogind|seatd|dbus'
# Check user groups
groups $USER  # needs: video, input, seat, wheel, audio
# Test sway manually
sway  # from TTY
```

### SD card wear / performance
```bash
# Check writes
iostat -dx 5 /dev/mmcblk0
# Manual TRIM
fstrim -v /mnt/data
# Check health (if supported)
smartctl -a /dev/mmcblk0
```

## Recovery Commands

```bash
# Unlock data partition manually
alpine-recovery.sh unlock /dev/mmcblk0p3 /path/to/key.bin

# Mount all subvolumes
alpine-recovery.sh mount-data /dev/mmcblk0p3 /path/to/key.bin

# Restore LBU backup to new SD card
alpine-recovery.sh restore-lbu /backup/localhost.apkovl.tar.gz /dev/mmcblk0p1

# Chroot into boot partition for repairs
alpine-recovery.sh chroot-boot /dev/mmcblk0p1

# Full verification
alpine-recovery.sh verify
```

## Package Management Notes

- **Packages install to RAM** (tmpfs root)
- **APK cache on ext4 partition** survives reboot
- **`lbu commit` saves:** /etc changes, package list, new packages to cache
- **Kernel updates need:** `update-kernel /media/usb/boot` then `lbu commit`

## Security

- Boot partition is **UNENCRYPTED** - physical access = config access
- Encrypt LBU backups: `lbu encrypt` or `LBU_ENCRYPT=aes-256-cbc lbu commit`
- ext4 partition contains system configs (not user data)
- Key file on boot partition = data partition unlockable if SD stolen
- For high security: use passphrase only (stored in dmcrypt config), or store key on separate USB if desired

## Performance Optimizations Active

- `noatime` on all mounts
- `discard=async` (Btrfs async TRIM)
- `compress=zstd` (reduces physical writes)
- `space_cache=v2` (faster mounts)
- zram swap (no SD swap writes)
- tmpfs for `/tmp`, `/var/tmp`, `/var/cache`
- Weekly fstrim cron
- Minimal syslog

## Upgrading Alpine Version

1. Update repositories in `/media/usb/etc/apk/repositories`
2. `apk update && apk upgrade --available`
3. `update-kernel /media/usb/boot`
4. `lbu commit`
5. Reboot

## Adding a Second User

```bash
setup-user -g "wheel,video,audio,input,seat" -h /home/newuser newuser
# Home will be created on encrypted partition at first login
```

---

**Remember: `lbu commit` is your save button. Use it often!**