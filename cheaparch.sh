#!/bin/bash

# Exit on error
set -e

# Variables (edit these as needed)
DISK="/dev/sda" # Replace with your actual disk
HOSTNAME="chatgpt"
USERNAME="joe" # Replace with your desired username
PASSWORD="joejoejoe" # Replace with your password
SWAP_SIZE="8G"

# Function to print status messages
info() {
    echo -e "\n\e[1;34m[INFO] $1\e[0m\n"
}

# Step 1: Partition the Disk
info "Partitioning the disk..."
parted --script "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 boot on \
    mkpart primary btrfs 513MiB 100%

# Step 2: Format Partitions
info "Formatting partitions..."
mkfs.fat -F32 "${DISK}1"
mkfs.btrfs -f "${DISK}2"

# Step 3: Create BTRFS Subvolumes
info "Creating BTRFS subvolumes..."
mount "${DISK}2" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@tmp
umount /mnt

# Step 4: Mount Subvolumes
info "Mounting subvolumes..."
mount -o subvol=@,compress=zstd "${DISK}2" /mnt
mkdir -p /mnt/{home,var/log,var/cache,root,srv,tmp,boot/efi}
mount -o subvol=@home "${DISK}2" /mnt/home
mount -o subvol=@var_log "${DISK}2" /mnt/var/log
mount -o subvol=@var_cache "${DISK}2" /mnt/var/cache
mount -o subvol=@root "${DISK}2" /mnt/root
mount -o subvol=@srv "${DISK}2" /mnt/srv
mount -o subvol=@tmp "${DISK}2" /mnt/tmp
mount "${DISK}1" /mnt/boot/efi

# Step 5: Install Base System
info "Installing base system..."
pacstrap /mnt base linux linux-firmware btrfs-progs sudo nano vim grub efibootmgr networkmanager snapper

# Step 6: Generate FSTAB
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Step 7: Configure System
info "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
# Set timezone and locale
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
echo "de_DE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=de_DE.UTF-8" > /etc/locale.conf
echo "KEYMAP=de" > /etc/vconsole.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1 localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# Set root password
echo "root:$PASSWORD" | chpasswd

# Create a user
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Install and configure GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Install a Desktop
pacman -Sy --noconfirm --needed lightdm lightdm-gtk-greeter fluxbox xterm xfce4-terminal xorg-server

# Enable necessary services
systemctl enable NetworkManager lightdm
EOF

# Step 8: Create Swap File with Hibernate Support
info "Creating swap file..."
fallocate -l "$SWAP_SIZE" /mnt/swapfile   # This will create a swap file with no holes
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
echo "/swapfile none swap sw 0 0" >> /mnt/etc/fstab

# Step 9: Final Steps
info "Installation complete! Unmounting and rebooting..."
umount -R /mnt
reboot