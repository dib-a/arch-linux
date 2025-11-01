#!/usr/bin/env bash
# ================================================================
#  Arch Linux Minimal Installation Script (Encrypted or Plain Root)
#  Author: dib-a
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
DEFAULT_ENCRYPT="y"
DEFAULT_SSH="n"
DEFAULT_UFW="n"
# ================================================================

echo "=== Arch Linux Minimal Installation Script ==="
echo "This will ERASE the selected disk and install Arch Linux."
echo

# --- User Inputs with Defaults ---
read -rp "Enter target disk [${DEFAULT_DISK}]: " DISK
DISK=${DISK:-$DEFAULT_DISK}

read -rp "Encrypt root partition? [y/N] [${DEFAULT_ENCRYPT}]: " ENCRYPT
ENCRYPT=${ENCRYPT:-$DEFAULT_ENCRYPT}

read -rp "Install and enable SSH? [y/N] [${DEFAULT_SSH}]: " SSH
SSH=${SSH:-$DEFAULT_SSH}

read -rp "Install and enable UFW firewall? [y/N] [${DEFAULT_UFW}]: " UFW
UFW=${UFW:-$DEFAULT_UFW}

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
echo "Disk:         $DISK"
echo "Encrypt root: $ENCRYPT"
echo "SSH enabled:  $SSH"
echo "UFW enabled:  $UFW"
echo "Hostname:     $HOSTNAME"
echo "Username:     $USERNAME"
echo "Timezone:     $TIMEZONE"
echo "Locale:       $LOCALE"
echo "Keymap:       $KEYMAP"
echo "================"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

# ================================================================
#  Partitioning
# ================================================================
echo "[1/13] Partitioning $DISK..."
loadkeys "$KEYMAP"
timedatectl set-ntp true

wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 301MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 301MiB 100%

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
[[ "$DISK" == *"nvme"* ]] && {
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
}

mkfs.fat -F32 -n EFI "$EFI_PART"

# ================================================================
#  Optional Encryption Setup
# ================================================================
if [[ "$ENCRYPT" =~ ^[Yy]$ ]]; then
  echo "[2/13] Setting up LUKS2 encryption on $ROOT_PART..."
  cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 \
    --key-size 512 --hash sha512 --iter-time 5000 "$ROOT_PART"
  cryptsetup open "$ROOT_PART" cryptroot
  ROOT_MAPPER="/dev/mapper/cryptroot"
else
  echo "[2/13] Skipping encryption for root..."
  ROOT_MAPPER="$ROOT_PART"
fi

# ================================================================
#  Filesystems and Mounting
# ================================================================
echo "[3/13] Formatting and mounting..."
mkfs.ext4 -L ROOT "$ROOT_MAPPER"
mount -L ROOT /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# ================================================================
#  Base Installation
# ================================================================
echo "[4/13] Installing base system..."
PKGS="base linux linux-firmware neovim dhcpcd grub efibootmgr sudo"
if [[ "$SSH" =~ ^[Yy]$ ]]; then
  PKGS+=" openssh"
fi
if [[ "$UFW" =~ ^[Yy]$ ]]; then
  PKGS+=" ufw"
fi

pacstrap -K /mnt $PKGS

# ================================================================
#  System Configuration
# ================================================================
echo "[5/13] Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Create configuration script inside chroot
cat <<EOF > /mnt/root/chroot_config.sh
#!/usr/bin/env bash
set -euo pipefail

echo "[6/13] Configuring system timezone and locale..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i "s/^#\(${LOCALE}.*\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "[7/13] Setting hostname..."
echo "$HOSTNAME" > /etc/hostname

# Setup mkinitcpio hooks for encryption if needed
if [[ "$ENCRYPT" =~ ^[Yy]$ ]]; then
  echo "[8/13] Configuring initramfs for encryption..."
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
else
  echo "[8/13] Configuring standard initramfs..."
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Configure GRUB
echo "[9/13] Installing and configuring GRUB bootloader..."
sed -i '/^GRUB_ENABLE_CRYPTODISK=/d' /etc/default/grub

if [[ "$ENCRYPT" =~ ^[Yy]$ ]]; then
  echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
  CRYPTUUID=\$(blkid -s UUID -o value $ROOT_PART)
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$CRYPTUUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchLinux \
  $([[ "$ENCRYPT" =~ ^[Yy]$ ]] && echo '--modules="luks cryptodisk"') --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Networking
systemctl enable dhcpcd

# SSH setup
if [[ "$SSH" =~ ^[Yy]$ ]]; then
  echo "[10/13] Setting up SSH..."
  systemctl enable sshd
  ssh-keygen -A
fi

# Firewall setup
if [[ "$UFW" =~ ^[Yy]$ ]]; then
  echo "[11/13] Setting up UFW firewall..."
  systemctl enable ufw
  if [[ "$SSH" =~ ^[Yy]$ ]]; then
    ufw allow ssh
  fi
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
fi

# Root password
echo "[12/13] Set root password:"
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
if [[ "$ENCRYPT" =~ ^[Yy]$ ]]; then
  cryptsetup close cryptroot
fi

echo "=== Installation Complete ==="
if [[ "$SSH" =~ ^[Yy]$ ]]; then
  echo "SSH is enabled by default. You can connect after boot."
fi
if [[ "$UFW" =~ ^[Yy]$ ]]; then
  echo "UFW firewall is enabled."
  [[ "$SSH" =~ ^[Yy]$ ]] && echo "SSH is allowed through the firewall."
fi
echo "Rebooting in 10 seconds..."
sleep 10
reboot
