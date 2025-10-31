#!/usr/bin/env bash
# arch-luks-install.sh
# Interactive Arch Linux minimal installer with LUKS2 full-disk encryption
# WARNING: This script WILL WIPE the chosen disk. Run only on the Arch live ISO and only on a disk you want to erase.

set -euo pipefail

# --- Helpers ---
confirm() {
  local prompt="${1:-Are you sure? [y/N]: }"
  read -r -p "$prompt" ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

part_suffix() {
  # returns "p" if device name contains "nvme" (nvme devices use p1,p2...), else ""
  if [[ "$1" == *"nvme"* || "$1" == *"mmcblk"* ]]; then
    echo "p"
  else
    echo ""
  fi
}

# --- Intro & checks ---
if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root from the Arch Linux live ISO."
  exit 1
fi

for cmd in parted cryptsetup mkfs.fat mkfs.ext4 pacstrap genfstab arch-chroot grub-install grub-mkconfig blkid; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in live environment."
    echo "Make sure you booted the Arch installation medium and have a working internet connection."
    exit 1
  fi
done

cat <<'EOF'
=====================================================================
 Arch Linux Minimal Installer (LUKS2 encrypted root) - Interactive
 WARNING: This will ERASE the target disk.
=====================================================================
EOF

# --- User input ---
read -r -p "Target disk (e.g. /dev/sda or /dev/nvme0n1): " DISK
if [[ ! -b "$DISK" ]]; then
  echo "Device $DISK not found or not a block device."
  exit 1
fi
SUFFIX=$(part_suffix "$DISK")

echo "Detected partition suffix: '$SUFFIX'"

read -r -p "Use default EFI size 1MiB-513MiB and rest for LUKS? [Y/n]: " use_default
if [[ -z "$use_default" || "$use_default" =~ ^[Yy] ]]; then
  EFI_START=1MiB
  EFI_END=513MiB
  ROOT_START=513MiB
else
  read -r -p "EFI start (e.g. 1MiB): " EFI_START
  read -r -p "EFI end (e.g. 513MiB): " EFI_END
  read -r -p "Root start (e.g. 513MiB): " ROOT_START
fi

read -r -p "Enter timezone (Region/City), e.g. Europe/Berlin: " TIMEZONE
read -r -p "Enter locale (e.g. en_US.UTF-8): " LOCALE
read -r -p "Enter hostname: " HOSTNAME
read -r -p "Enter username (your regular user): " NEWUSER

# passwords and passphrase (hidden)
read -s -r -p "Enter root password: " ROOTPASS && echo
read -s -r -p "Enter password for user '$NEWUSER': " USERPASS && echo
echo "Enter LUKS passphrase (you will need this on every boot):"
read -s -r -p "LUKS passphrase: " LUKSPHRASE && echo

echo
echo "SUMMARY"
echo " Disk: $DISK"
echo " EFI partition: ${DISK}${SUFFIX}1"
echo " Encrypted root partition: ${DISK}${SUFFIX}2"
echo " Timezone: $TIMEZONE"
echo " Locale: $LOCALE"
echo " Hostname: $HOSTNAME"
echo " Username: $NEWUSER"
echo
confirm "Proceed and wipe $DISK? This will destroy all data on the disk. [y/N]: " || { echo "Aborted."; exit 1; }

# --- Partitioning ---
echo "Wiping signatures on $DISK..."
wipefs -a "$DISK"

echo "Creating GPT and partitions..."
parted --script "$DISK" mklabel gpt
parted --script "$DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
parted --script "$DISK" set 1 esp on
# shellcheck disable=SC2086
parted --script "$DISK" mkpart primary ext4 $ROOT_START 100%

EFI_PART="${DISK}${SUFFIX}1"
ROOT_PART="${DISK}${SUFFIX}2"

echo "Formatting EFI partition $EFI_PART as FAT32..."
mkfs.fat -F32 -n EFI "$EFI_PART"

# --- LUKS2 encryption ---
echo "Setting up LUKS2 on $ROOT_PART..."
# Use luks2 with aes-xts and sha512
# Using --pbkdf arg omitted to rely on defaults; you can tune iter/time if desired
printf "%s" "$LUKSPHRASE" | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --batch-mode "$ROOT_PART"
printf "%s" "$LUKSPHRASE" | cryptsetup open "$ROOT_PART" cryptroot

# --- Filesystems ---
ROOT_MAPPER="/dev/mapper/cryptroot"
echo "Creating ext4 filesystem on $ROOT_MAPPER..."
mkfs.ext4 -L ROOT "$ROOT_MAPPER"

# --- Mount ---
echo "Mounting filesystems..."
mount -L ROOT /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# --- Mirror refresh (optional but recommended) ---
if command -v reflector >/dev/null 2>&1; then
  echo "Refreshing mirrorlist with reflector..."
  reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || true
fi

# --- Install base packages (including neovim) ---
echo "Installing base system (this may take a while)..."
pacstrap -K /mnt base linux linux-firmware neovim archlinux-keyring

# --- fstab ---
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# --- Save secrets for chroot script (secure files inside /mnt, will be deleted later) ---
echo "Saving secrets for post-install (kept temporarily in the new system)..."
echo "$ROOTPASS" > /mnt/root/.rootpw
echo "$USERPASS" > /mnt/root/.userpw
chmod 600 /mnt/root/.rootpw /mnt/root/.userpw

# --- Create post-install script (runs inside arch-chroot) ---
cat > /mnt/root/post_install.sh <<'EOCHROOT'
#!/usr/bin/env bash
set -euo pipefail

# Post-install config inside chroot
# Files with passwords: /root/.rootpw and /root/.userpw (read and removed)
ROOTPW_FILE="/root/.rootpw"
USERPW_FILE="/root/.userpw"

if [[ ! -f "$ROOTPW_FILE" || ! -f "$USERPW_FILE" ]]; then
  echo "Password files missing. Exiting."
  exit 1
fi

ROOTPASS="$(cat "$ROOTPW_FILE")"
USERPASS="$(cat "$USERPW_FILE")"
# Clear the files after reading
shred -u "$ROOTPW_FILE" || rm -f "$ROOTPW_FILE"
shred -u "$USERPW_FILE" || rm -f "$USERPW_FILE"

read -r TIMEZONE LOCALE HOSTNAME NEWUSER <<< "$(cat /root/.installer_meta)"
# timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# locale
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# hostname
echo "$HOSTNAME" > /etc/hostname
# basic hosts
cat >/etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOSTNAME.localdomain	$HOSTNAME
HOSTS

# mkinitcpio: ensure encrypt hook present
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install and configure grub (UEFI)
pacman -S --noconfirm grub efibootmgr dosfstools

# Find UUID of the encrypted device
LUKS_UUID=$(blkid -s UUID -o value "$(grep cryptroot /etc/fstab >/dev/null 2>&1 || true; blkid -t TYPE=crypto_LUKS -o device | head -n1)" 2>/dev/null || true)
# Better: search for crypto LUKS device and retrieve UUID
LUKS_DEV=$(blkid -t TYPE=crypto_LUKS -o device | head -n1)
if [[ -n "$LUKS_DEV" ]]; then
  LUKS_UUID="$(blkid -s UUID -o value "$LUKS_DEV")"
fi

# Fallback: attempt to get disk from /dev/disk/by-label/ROOT
if [[ -z "$LUKS_UUID" ]]; then
  LUKS_UUID=$(blkid -s UUID -o value $(blkid | grep ROOT | cut -d: -f1) 2>/dev/null || true)
fi

# Create /etc/crypttab to map cryptroot at boot (optional for cryptsetup by systemd)
echo "cryptroot UUID=$LUKS_UUID none luks,discard" > /etc/crypttab

# GRUB kernel param (use UUID)
if [[ -n "$LUKS_UUID" ]]; then
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub || \
  echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot\"" >> /etc/default/grub
else
  echo "WARNING: Could not determine LUKS UUID automatically. You must edit /etc/default/grub later."
fi

# Install GRUB to UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchLinux --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# set root password
echo "root:$ROOTPASS" | chpasswd

# create user, add to wheel
useradd -m -G wheel -s /bin/bash "$NEWUSER"
echo "$NEWUSER:$USERPASS" | chpasswd

# allow wheel group sudo
pacman -S --noconfirm sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# enable dhcpcd for simple network
pacman -S --noconfirm dhcpcd
systemctl enable dhcpcd

# install some comfort packages (neovim already installed by pacstrap in live)
pacman -S --noconfirm bash-completion man-db man-pages less

echo "Post-install steps complete. Remove /root/post_install.sh if you want."
EOCHROOT

# --- prepare meta info to pass into chroot script ---
cat > /mnt/root/.installer_meta <<EOF
$TIMEZONE $LOCALE $HOSTNAME $NEWUSER
EOF

chmod +x /mnt/root/post_install.sh

# --- Chroot and run post-install ---
echo "Entering chroot to perform final configuration..."
arch-chroot /mnt /root/post_install.sh

# --- Cleanup and final notes ---
echo "Cleaning up and unmounting..."
umount -R /mnt || true
cryptsetup close cryptroot || true

cat <<EOF

=====================================================================
 Installation finished (script completed)
 - Remove the installation media and reboot.
 - On first boot you will be asked for the LUKS passphrase to unlock the root filesystem.
 - If grub does not show or the kernel cannot find the root device, boot from live media and inspect:
     - /boot/grub/grub.cfg
     - /etc/default/grub
     - blkid output to verify UUIDs
=====================================================================

EOF
