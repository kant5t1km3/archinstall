#!/bin/bash

encryption_passphrase=""
root_password=""
user_password=""
hostname=""
user_name=""
continent_city=""
swap_size="16"

echo "Updating system clock"
timedatectl set-ntp true

# echo "Refreshing PGP keys"
# pacman-key --init
# pacman-key --populate archlinux
# pacman -Sc --noconfirm
# pacman -Sy --noconfirm gnupg archlinux-keyring

echo "Syncing packages database and Finding Mirrors"
pacman -Sy reflector --noconfirm
reflector -a 2 -l 100 -f 10 --sort score --save /etc/pacman.d/mirrorlist

echo "Creating partition tables"
printf "n\n1\n4096\n+512M\nef00\nw\ny\n" | gdisk /dev/nvme0n1
printf "n\n2\n\n\n8e00\nw\ny\n" | gdisk /dev/nvme0n1

#echo "Zeroing partitions"
#cat /dev/zero > /dev/nvme0n1p1
#cat /dev/zero > /dev/nvme0n1p2

echo "Setting up cryptographic volume"
modprobe dm-crypt
modprobe dm-mod
printf "%s" "$encryption_passphrase" | cryptsetup -h sha512 -s 512 --use-random --type luks2 luksFormat /dev/nvme0n1p2
printf "%s" "$encryption_passphrase" | cryptsetup luksOpen /dev/nvme0n1p2 cryptlvm

echo "Creating physical volume"
pvcreate /dev/mapper/cryptlvm

echo "Creating volume volume"
vgcreate vg0 /dev/mapper/cryptlvm

echo "Creating logical volumes"
lvcreate -L +"$swap_size"GB vg0 -n swap
lvcreate -l +100%FREE vg0 -n root

echo "Setting up / partition"
yes | mkfs.ext4 /dev/vg0/root
mount /dev/vg0/root /mnt

echo "Setting up /boot partition"
yes | mkfs.fat -F32 /dev/nvme0n1p1
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

echo "Setting up swap"
yes | mkswap /dev/vg0/swap
swapon /dev/vg0/swap

echo "Installing Arch Linux"
yes '' | pacstrap /mnt base base-devel linux linux-headers linux-lts linux-lts-headers linux-firmware lvm2 device-mapper e2fsprogs intel-ucode cryptsetup networkmanager wget man-db man-pages nano diffutils flatpak mkinitcpio vi vim reflector dhcpcd git sudo efibootmgr xf86-video-intel dialog wpa_supplicant

echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "Configuring new system"
arch-chroot /mnt /bin/bash <<EOF

echo "Setting system clock"
ln -sf /usr/share/zoneinfo/$continent_city /etc/localtime
hwclock --systohc --localtime

echo "Setting locales"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
locale-gen

echo "Adding persistent keymap"
echo "KEYMAP=us" > /etc/vconsole.conf

echo "Setting hostname"
echo $hostname > /etc/hostname

echo "Setting root password"
echo -en "$root_password\n$root_password" | passwd

echo "Creating new user"
useradd -m -G wheel -s /bin/bash $user_name
mkdir -p /home/"$user_name" && chown "$user_name":wheel /home/"$user_name"
echo -en "$user_password\n$user_password" | passwd $user_name

echo "Generating initramfs"
sed -i 's/^HOOKS.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt sd-lvm2 filesystems fsck shutdown)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES.*/MODULES=(ext4 i915 lz4 lz4_compress)/' /etc/mkinitcpio.conf
sed -i 's/^BINARIES.*/BINARIES=(fsck fsck.ext4)/' /etc/mkinitcpio.conf
sed -i 's/#COMPRESSION="lz4"/COMPRESSION="lz4"/g' /etc/mkinitcpio.conf
sed -i 's/#COMPRESSION_OPTIONS=()/COMPRESSION_OPTIONS=(-9)/g' /etc/mkinitcpio.conf

mkinitcpio -p linux
mkinitcpio -p linux-lts

echo "Setting up systemd-boot"
bootctl --path=/boot install

mkdir -p /boot/loader/
touch /boot/loader/loader.conf
tee -a /boot/loader/loader.conf << END
default arch
timeout 0
editor 0
END

mkdir -p /boot/loader/entries/
touch /boot/loader/entries/arch.conf
tee -a /boot/loader/entries/arch.conf << END
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=$(blkid -s UUID -o value /dev/nvme0n1p2)=cryptlvm root=/dev/vg0/root resume=/dev/vg0/swap rd.luks.options=discard elevator=none i915.fastboot=1 i915.enable_psr=1 quiet loglevel=3 splash rw
END

touch /boot/loader/entries/archlts.conf
tee -a /boot/loader/entries/archlts.conf << END
title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /intel-ucode.img
initrd /initramfs-linux-lts.img
options rd.luks.name=$(blkid -s UUID -o value /dev/nvme0n1p2)=cryptlvm root=/dev/vg0/root resume=/dev/vg0/swap rd.luks.options=discard elevator=none i915.fastboot=1 i915.enable_psr=1 quiet loglevel=3 splash rw
END

echo "Setting up Pacman hook for automatic systemd-boot updates"
mkdir -p /etc/pacman.d/hooks/
touch /etc/pacman.d/hooks/systemd-boot.hook

tee -a /etc/pacman.d/hooks/systemd-boot.hook << END
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd
[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
END

echo "Setting up Pacman hook for Mirror Sync"
touch /etc/pacman.d/hooks/mirrorupgrade.hook

tee -a /etc/pacman.d/hooks/mirrorupgrade.hook << END
[Trigger]
Operation = Upgrade
Type = Package
Target = pacman-mirrorlist
[Action]
Description = Updating pacman-mirrorlist with reflector and removing pacnew...
When = PostTransaction
Depends = reflector
Exec = /bin/sh -c "reflector -a 2 -l 100 -f 10 --sort score --save /etc/pacman.d/mirrorlist; rm -f /etc/pacman.d/mirrorlist.pacnew"
END

echo "Setting up Scheduler Rules"
mkdir -p /etc/udev.d/
touch /etc/udev.d/60-scheduler.rules
tee -a /etc/udev.d/60-scheduler.rules << END
# set scheduler for NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
# set scheduler for SSD and eMMC
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# set scheduler for rotating disks
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
END

echo "Setting Journal Limit"
sed -i 's/#SystemMaxUse=/SystemMaxUse=100M/g' /etc/systemd/journald.conf

echo "Enabling periodic TRIM"
systemctl enable fstrim.timer

echo "Enabling Network Manager"
systemctl enable NetworkManager

echo "User Config"
echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo
sed -i "s/^#Color$/Color/" /etc/pacman.conf
sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf
systembeepoff

echo "Setting autologin"
mkdir -p /etc/systemd/system/getty@tty1.service.d
tee -a /etc/systemd/system/getty@tty1.service.d/override.conf << END
[Service]
Type=Simple
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $user_name --noclear %I \$TERM
END

# Exit arch-chroot
EOF

umount -R /mnt
swapoff -a

echo "ArchLinux is ready. You can reboot now!"
