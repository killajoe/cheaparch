#!/bin/bash

# Exit on error
set -e

# Variables (edit these as needed)
DISK="/dev/sda" # Replace with your actual disk
HOSTNAME="cheaparch"
USERNAME="joe" # Replace with your desired username
PASSWORD="joe" # Replace with your password
SWAP_SIZE="8g" # Replace with the size of your swap
REGION="Europe"
CITY="Berlin"

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
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@swap
umount /mnt

# Step 4: Mount Subvolumes
info "Mounting subvolumes..."
mount -o subvol=@,compress=zstd "${DISK}2" /mnt
mkdir -p /mnt/{home,var/log,var/cache,boot/efi,swap}
mount -o subvol=@home "${DISK}2" /mnt/home
mount -o subvol=@log "${DISK}2" /mnt/var/log
mount -o subvol=@cache "${DISK}2" /mnt/var/cache
mount -o subvol=@swap "${DISK}2" /mnt/swap
mount "${DISK}1" /mnt/boot/efi

# Step 5: Create Swap File with Hibernate Support
info "Creating swap file..."
btrfs filesystem mkswapfile --size "$SWAP_SIZE" --uuid clear /mnt/swap/swapfile

# Step 6: Install Base System
info "Installing base system..."
pacstrap /mnt base linux linux-firmware btrfs-progs sudo nano vim grub efibootmgr networkmanager snapper

# Step 7: Generate FSTAB
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
info "adding swapfile to fstab"
echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# Step 8: Configure System
info "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
# Set timezone and locale
ln -sf /usr/share/zoneinfo/"${region}"/"${city}" /etc/localtime
hwclock --systohc
echo "de_DE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=de_DE.UTF-8" > /etc/locale.conf
echo "KEYMAP=de-latin1" > /etc/vconsole.conf

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
pacman -Sy --noconfirm --needed lightdm lightdm-gtk-greeter fluxbox xterm xfce4-terminal xorg-server noto-fonts pipewire pipewire-jack pipewire-pulse firefox glances

# Enable necessary services
systemctl enable NetworkManager lightdm
EOF

# Step 9: Set resume_offset in GRUB and bootimages for Hibernate
info "Configuring hibernation with resume offset..."
SWAP_OFFSET=$(filefrag -v /mnt/swap/swapfile | awk '/ 0:/ {print $4}' | cut -d '.' -f 1)
sed -i "/^GRUB_CMDLINE_LINUX=/s|\"$|resume=/swap/swapfile resume_offset=$SWAP_OFFSET\"|" /mnt/etc/default/grub
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck resume)/' /mnt/etc/mkinitcpio.conf

info "Configuring resume for kernel image..."
arch-chroot /mnt /bin/bash <<EOF 
grub-mkconfig -o /boot/grub/grub.cfg
mkinitcpio -P
EOF

# Step 11: Snapper Configuration (Workaround for DBus in chroot)
info "Configuring Snapper for regular snapshots..."

# We will configure Snapper outside the chroot due to DBus issues inside chroot

# Create Snapper configurations for / and /home outside of the chroot
pacman -Sy --noconfirm snapper
snapper -c root create-config /mnt/
snapper -c home create-config /mnt/home

# Configure the snapshotting interval
echo "TIMELINE_CREATE=yes" >> /mnt/etc/snapper/configs/root
echo "TIMELINE_LIMIT_HOURLY=24" >> /mnt/etc/snapper/configs/root
echo "TIMELINE_LIMIT_DAILY=5" >> /mnt/etc/snapper/configs/root

echo "TIMELINE_CREATE=yes" >> /mnt/etc/snapper/configs/home
echo "TIMELINE_LIMIT_HOURLY=24" >> /mnt/etc/snapper/configs/home
echo "TIMELINE_LIMIT_DAILY=5" >> /mnt/etc/snapper/configs/home

# Enable and start Snapper timers to run automatically
arch-chroot /mnt systemctl enable snapper-timeline.timer
arch-chroot /mnt systemctl start snapper-timeline.timer


# Step 12: Final Steps
info "Installation complete! Unmounting and rebooting..."
umount -R /mnt
echo "system will reboot into your "$HOSTNAME" install in 10 seconds:"
sleep 10
reboot
