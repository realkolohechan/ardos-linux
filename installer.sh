#!/usr/bin/env bash
set -euo pipefail

# ARDOS installer
# WARNING: This script can ERASE DATA if used incorrectly.
# Make sure you know what you’re doing and have backups.

ROOTFS_DIR="ardos"   # folder containing the prepared rootfs (/, boot, etc)
MOUNT_POINT="/mnt/ardos"

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${GREEN}=== ARDOS Installer ===${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${NC}"
    exit 1
fi

if [[ ! -d "$ROOTFS_DIR" ]]; then
    echo -e "${RED}Rootfs directory '$ROOTFS_DIR' not found.${NC}"
    echo "Make sure the prepared rootfs is in ./$ROOTFS_DIR"
    exit 1
fi

echo
echo -e "${YELLOW}Available disks:${NC}"
lsblk -dpno NAME,SIZE,TYPE | grep "disk" || true
echo

read -rp "Enter the target DISK (e.g. /dev/sda): " TARGET_DISK
if [[ ! -b "$TARGET_DISK" ]]; then
    echo -e "${RED}Invalid disk: $TARGET_DISK${NC}"
    exit 1
fi

echo
echo -e "${YELLOW}Available partitions on $TARGET_DISK:${NC}"
lsblk -pno NAME,SIZE,TYPE "$TARGET_DISK" | grep "part" || true
echo

read -rp "Enter the root PARTITION to install ARDOS to (e.g. /dev/sda1): " ROOT_PART
if [[ ! -b "$ROOT_PART" ]]; then
    echo -e "${RED}Invalid partition: $ROOT_PART${NC}"
    exit 1
fi

echo
read -rp "Do you want to format $ROOT_PART as ext4? [y/N]: " FORMAT_ROOT
FORMAT_ROOT=${FORMAT_ROOT,,}

if [[ "$FORMAT_ROOT" == "y" ]]; then
    echo -e "${YELLOW}Formatting $ROOT_PART as ext4...${NC}"
    mkfs.ext4 -F "$ROOT_PART"
fi

echo
echo -e "${YELLOW}Detecting partition table type for $TARGET_DISK...${NC}"
PART_TABLE=$(parted -s "$TARGET_DISK" print | awk '/Partition Table:/ {print $3}')

if [[ "$PART_TABLE" == "gpt" ]]; then
    PT_TYPE="GPT"
elif [[ "$PART_TABLE" == "msdos" ]]; then
    PT_TYPE="MSDOS"
else
    PT_TYPE="UNKNOWN"
fi

echo -e "Partition table type: ${GREEN}$PT_TYPE${NC}"

echo
read -rp "Is GRUB already installed for this disk? [y/N]: " HAS_GRUB
HAS_GRUB=${HAS_GRUB,,}

# Mount root partition
echo
echo -e "${YELLOW}Mounting root partition $ROOT_PART at $MOUNT_POINT...${NC}"
mkdir -p "$MOUNT_POINT"
mount "$ROOT_PART" "$MOUNT_POINT"

# Copy rootfs
echo
echo -e "${YELLOW}Copying ARDOS rootfs from $ROOTFS_DIR to $MOUNT_POINT...${NC}"
# You can replace rsync with cp -a if rsync isn't available
if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX "$ROOTFS_DIR"/ "$MOUNT_POINT"/
else
    cp -a "$ROOTFS_DIR"/. "$MOUNT_POINT"/
fi

# Ensure /boot exists
mkdir -p "$MOUNT_POINT/boot"

# Optional: /boot/efi for EFI systems
EFI_PART=""
if [[ "$PT_TYPE" == "GPT" ]]; then
    echo
    read -rp "Do you want to use/create a separate EFI partition? [y/N]: " USE_EFI
    USE_EFI=${USE_EFI,,}

    if [[ "$USE_EFI" == "y" ]]; then
        echo
        echo -e "${YELLOW}Existing partitions (for EFI selection/creation):${NC}"
        lsblk -pno NAME,SIZE,TYPE "$TARGET_DISK" | grep "part" || true

        read -rp "Enter EFI PARTITION (e.g. /dev/sda1), or leave blank to skip: " EFI_PART
        if [[ -n "$EFI_PART" ]]; then
            if [[ ! -b "$EFI_PART" ]]; then
                echo -e "${RED}Invalid EFI partition: $EFI_PART${NC}"
                exit 1
            fi

            # Optionally format as FAT32 if empty
            echo
            read -rp "Format $EFI_PART as FAT32? [y/N]: " FORMAT_EFI
            FORMAT_EFI=${FORMAT_EFI,,}
            if [[ "$FORMAT_EFI" == "y" ]]; then
                echo -e "${YELLOW}Formatting $EFI_PART as FAT32...${NC}"
                mkfs.fat -F32 "$EFI_PART"
            fi

            mkdir -p "$MOUNT_POINT/boot/efi"
            mount "$EFI_PART" "$MOUNT_POINT/boot/efi"
        fi
    fi
fi

# Generate fstab
echo
echo -e "${YELLOW}Generating /etc/fstab...${NC}"

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART" || true)
EFI_UUID=""
if [[ -n "$EFI_PART" ]]; then
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART" || true)
fi

FSTAB="$MOUNT_POINT/etc/fstab"

cp "$FSTAB" "$FSTAB.bak.$(date +%s)" 2>/dev/null || true

{
    echo "# /etc/fstab: static file system information."
    echo "# <file system> <mount point> <type> <options> <dump> <pass>"
    echo
    if [[ -n "$ROOT_UUID" ]]; then
        echo "UUID=$ROOT_UUID  /          ext4  defaults  0 1"
    else
        echo "# WARNING: UUID for root not found; using device path"
        echo "$ROOT_PART       /          ext4  defaults  0 1"
    fi

    if [[ -n "$EFI_UUID" ]]; then
        echo "UUID=$EFI_UUID   /boot/efi  vfat  umask=0077  0 1"
    fi

    echo "tmpfs            /tmp       tmpfs defaults    0 0"
} > "$FSTAB"

echo -e "${GREEN}/etc/fstab generated.${NC}"

# Install GRUB if needed
if [[ "$HAS_GRUB" != "y" ]]; then
    echo
    echo -e "${YELLOW}Installing GRUB into chroot...${NC}"

    mount --bind /dev  "$MOUNT_POINT/dev"
    mount --bind /proc "$MOUNT_POINT/proc"
    mount --bind /sys  "$MOUNT_POINT/sys"

    if [[ -n "$EFI_PART" ]]; then
        # UEFI GRUB install
        chroot "$MOUNT_POINT" bash -c "
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARDOS --recheck
            grub-mkconfig -o /boot/grub/grub.cfg
        "
    else
        # BIOS GRUB install (MBR or BIOS-GPT)
        chroot "$MOUNT_POINT" bash -c "
            grub-install --target=i386-pc $TARGET_DISK --recheck
            grub-mkconfig -o /boot/grub/grub.cfg
        "
    fi

    umount "$MOUNT_POINT/dev" "$MOUNT_POINT/proc" "$MOUNT_POINT/sys"

    echo -e "${GREEN}GRUB installation completed.${NC}"
else
    echo
    echo -e "${YELLOW}Skipping GRUB installation (user said GRUB already installed).${NC}"
fi

echo
echo -e "${GREEN}=== ARDOS installation finished ===${NC}"
echo "You can now reboot into your ARDOS system (after unmounting and removing the live USB)."
