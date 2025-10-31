#!/usr/bin/env bash
# ================================================================
#  Arch Linux Minimal Installation Script (with Full LUKS2 Encryption)
#  Author: [Your Name]
#  License: MIT
# ================================================================

set -euo pipefail

# ========================= DEFAULTS =============================
DEFAULT_DISK="/dev/sda"
DEFAULT_HOSTNAME="arch"
DEFAULT_USERNAME="user"
DEFAULT_TIMEZONE="Europe/Berlin"
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_KEYMAP="us"
# ================================================================

echo "=== Arch Linux Minimal Installation Script ==="
echo "This will ERASE the selected disk and install Arch Linux with full LUKS2 encryption."
echo

# --- User Inputs with Defaults ---
read -rp "Enter target disk [${DEFAULT_DISK}]: " DISK
DISK=${DISK:-$DEFAULT_DISK}

read -rp "Enter hostname [${DEFAULT_HOSTNAME}]: " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

read -rp "Enter username [${DEFAULT_USERNAME}]: " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USERNAME}

read -rp "Enter your timezone [${DEFAULT_TIMEZONE}]: " TIMEZONE
TIMEZONE=${TIMEZONE:-$DEFAULT_TIMEZONE}

read -rp "Enter your locale [${DEFAULT_LOCALE}]: " LOCALE
LOCALE=${LOCALE:-$DEFAULT_LOCALE}

read -rp "Enter keyboard layout [${DEFAULT_KEYMAP}]: " KEYMAP
KEYMAP=${KEYMAP:-$DEFAULT_KEYMAP}

echo
echo "=== SUMMARY ==="
echo "Disk:        $DISK"
echo "Hostname:    $HOSTNAME"
echo "Username:    $USERNAME"
echo "Timezone:    $TIMEZONE"
echo "Locale:      $LOCALE"
echo "Keymap:      $KEYMAP"
echo "================"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

# ================================================================
#  Partitioning
# ================================================================
echo "[1/10] Partitioning $DISK..."
loadkeys "$KEYMAP"
timedatectl set-ntp true

wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 301MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 301MiB 100%

EFI_PART="${DISK}1"
CRYPT_PART="${DISK}2"
[[ "$DISK" == *"nvme"* ]] && {
  EFI_PART="${DISK}p1"
  CRYPT_PART="${DISK}p2"
}

mkfs.fat -F32 -n EFI "$EFI_PART"

# ================================================================
#  Encryption Setup
# ================================================================
echo "[2/10] Setting up LUKS2 encryption on $CRYPT_PART..."
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 \
  --key-size 512 --hash sha512 --iter-time 5000 "$CRYPT_PART"

cryptsetup open "$CRYPT_PART" cryptroot

# ================================================================
#  Filesystems and Mounting
# ================================================================
echo "[3/10] Formatting and mounting..."
mkfs.ext4 -L ROOT /dev/mapper/cryptroot
mount -L ROOT /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# ================================================================
#  Base Installation
# ================================================================
echo "[4/10] Installing base system..."
pacstrap -K /mnt base linux linux-firmware neovim dhcpcd grub efibootmgr

# ================================================================
#  System Configuration
# ================================================================
echo "[5/10] Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Create configuration script inside chroot
cat <<EOF > /mnt/root/chroot_config.sh
#!/usr/bin/env bash
set -euo pipefail

echo "[6/10] Configuring system timezone and locale..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i "s/^#\(${LOCALE}.*\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "[7/10] Setting hostname..."
echo "$HOSTNAME" > /etc/hostname

# Setup mkinitcpio hooks for encryption
echo "[8/10] Configuring initramfs..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Detect LUKS UUID
CRYPTUUID=\$(blkid -s UUID -o value $CRYPT_PART)

# Configure GRUB
echo "[9/10] Installing and configuring GRUB bootloader..."
sed -i '/^GRUB_ENABLE_CRYPTODISK=/d' /etc/default/grub
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$CRYPTUUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchLinux --modules="luks cryptodisk" --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Networking
systemctl enable dhcpcd

# Root password
echo "[10/10] Set root password:"
passwd

# Create user
useradd -mG wheel $USERNAME
echo "Set password for user $USERNAME:"
passwd $USERNAME

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "=== Configuration inside chroot complete ==="
EOF

chmod +x /mnt/root/chroot_config.sh

# ================================================================
#  Chroot Execution
# ================================================================
echo "[*] Entering chroot to finalize installation..."
arch-chroot /mnt /root/chroot_config.sh

# ================================================================
#  Cleanup
# ================================================================
echo "[*] Cleaning up..."
rm /mnt/root/chroot_config.sh
umount -R /mnt
cryptsetup close cryptroot

echo "=== Installation Complete ==="
echo "You can now reboot into your encrypted Arch Linux system!"
echo "Rebooting in 10 seconds..."
sleep 10
reboot
