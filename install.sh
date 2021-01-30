#!/bin/bash

encryption_passphrase=''
root_password=''
#user_password=''
hostname=''
user_name=''
continent_city=''
swap_size='32'

echo "Updating system clock"
timedatectl set-ntp true

# echo "Refreshing PGP keys"
# pacman-key --init
# pacman-key --populate archlinux
# pacman -Sc --noconfirm
# pacman -Sy --noconfirm gnupg archlinux-keyring

echo "Syncing packages database and Finding Mirrors"
pacman -Sy reflector rsync --noconfirm
reflector --country "United States" -a 2 -l 100 -f 10 --sort score --save /etc/pacman.d/mirrorlist

echo "Creating partition tables"
blkdiscard /dev/nvme0n1 -f
printf "o\nw\ny\n" | gdisk /dev/nvme0n1
printf "n\n1\n4096\n+512M\nef00\nw\ny\n" | gdisk /dev/nvme0n1
printf "n\n2\n\n\n8300\nw\ny\n" | gdisk /dev/nvme0n1

#echo "Zeroing partitions"
#cat /dev/zero > /dev/nvme0n1p1
#cat /dev/zero > /dev/nvme0n1p2

echo "Setting up cryptographic volume"
modprobe dm-crypt
modprobe dm-mod
printf "%s" "$encryption_passphrase" | cryptsetup --use-random luksFormat /dev/nvme0n1p2
printf "%s" "$encryption_passphrase" | cryptsetup luksOpen /dev/nvme0n1p2 cryptroot

echo "Creating physical volume"
mkfs.fat -F32 -n LINUXEFI /dev/nvme0n1p1
mkfs.btrfs -L Arch /dev/mapper/cryptroot

mount -o compress=zstd,noatime /dev/mapper/cryptroot /mnt
btrfs subvol create /mnt/@
btrfs subvol create /mnt/@home
btrfs subvol create /mnt/@swap

mkdir /mnt/snapshots
btrfs subvol create /mnt/snapshots/@
btrfs subvol create /mnt/snapshots/@home

umount /mnt
mount -o compress=zstd,noatime,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home}
mount -o compress=zstd,noatime,subvol=@home /dev/mapper/cryptroot /mnt/home
mount /dev/nvme0n1p1 /mnt/boot

mkdir /mnt/var
btrfs subvol create /mnt/var/cache
btrfs subvol create /mnt/var/log

mkdir -p /mnt/var/lib/{mysql,postgres,machines}
chattr +C /mnt/var/lib/{mysql,postgres,machines}

echo "Installing Arch Linux"
yes '' | pacstrap /mnt base base-devel linux linux-headers linux-lts linux-lts-headers linux-firmware device-mapper e2fsprogs intel-ucode cryptsetup networkmanager wget man-db man-pages nano diffutils flatpak mkinitcpio btrfs-progs dosfstools vi vim rsync reflector dhcpcd git sudo efibootmgr sudo zsh zsh-completions zsh-syntax-highlighting xf86-video-intel dialog wpa_supplicant pigz ufw

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

#echo "Creating new user"
#useradd -m -G wheel -s /bin/bash $user_name
#mkdir -p /home/"$user_name" && chown "$user_name":wheel /home/"$user_name"
#echo -en "$user_password\n$user_password" | passwd $user_name

echo "Generating initramfs"
sed -i 's/^HOOKS.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf

mkinitcpio -p linux
mkinitcpio -p linux-lts

drive_id="$(blkid -s UUID -o value /dev/nvme0n1p2)"

echo "Setting up systemd-boot"
bootctl --path=/boot install

mkdir -p /boot/loader/
touch /boot/loader/loader.conf
tee -a /boot/loader/loader.conf << END
default arch.conf
timeout 2
editor 0
END

mkdir -p /boot/loader/entries/

touch /boot/loader/entries/archlts.conf
tee -a /boot/loader/entries/archlts.conf << END
title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /intel-ucode.img
initrd /initramfs-linux-lts.img
options rd.luks.name=$drive_id=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rd.luks.options=discard rw
END

touch /boot/loader/entries/arch.conf
tee -a /boot/loader/entries/arch.conf << END
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=$drive_id=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rd.luks.options=discard rw
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

mkinitcpio -p linux
mkinitcpio -p linux-lts

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
Exec = /bin/sh -c "reflector --country "United States" -a 2 -l 100 -f 10 --sort score --save /etc/pacman.d/mirrorlist; rm -f /etc/pacman.d/mirrorlist.pacnew"
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

echo "Do less swapping"
tee -a /etc/sysctl.d/99-swappiness.conf << END
vm.dirty_ratio = 6
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 1500
END

echo "Enabling Network Manager"
systemctl enable NetworkManager

echo "User Config"
timedatectl set-ntp true
reflector --country "United States" -a 2 -l 100 -f 10 --sort score --save /etc/pacman.d/mirrorlist
useradd -m -G wheel,libvirt,kvm,users -s /usr/bin/zsh aragorn
systemctl enable libvirtd

echo "Setting user password"
echo -en "$user_password\n$user_password" | passwd aragorn

echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo
systemctl enable fstrim.timer

wget https://raw.githubusercontent.com/brianclemens/dotfiles/011a0rootflags=subvol=@ rd.luks.options=discard rw80c6f5e87631623baf0aad826ff2b99566c/misc/sudoers.lecture
mv sudoers.lecture /etc/bee-sudoers.lecture
tee -a /etc/sudoers << END
Defaults    lecture=always
Defaults    lecture_file=/etc/bee-sudoers.lecture
END

#curl -LO larbs.xyz/larbs.sh
#sh larbs.sh

# Paru helper
sudo pacman -S --needed base-devel
git clone https://aur.archlinux.org/paru.git /tmp/paru
cd /tmp/paru
makepkg -si

# Plasma 
sudo pacman -S xorg-server xf86-video-fbdev xf86-video-nouveau xf86-video-intel adobe-source-code-pro-fonts noto-fonts-emoji virt-manager edk2-ovmf qemu libvirt firefox colord-kde plasma-meta sddm kdialog konsole dolphin noto-fonts phonon-qt5-vlc

sudo mkdir /etc/sddm.conf.d
tee -a /etc/sddm.conf.d/kde_settings.conf << END
[General]
HaltCommand=/usr/bin/systemctl poweroff
Numlock=none
RebootCommand=/usr/bin/systemctl reboot

[Theme]
Current=breeze

[Users]
MaximumUid=60000
MinimumUid=1000
END
sudo systemctl enable sddm

sed -i 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -z - --threads=0)/g' /etc/makepkg.conf
sed -i 's/COMPRESSGZ=(gzip -c -f -n)/COMPRESSGZ=(pigz -c -f -n)/g' /etc/makepkg.conf

#echo "Setting autologin"
#mkdir -p /etc/systemd/system/getty@tty1.service.d
#tee -a /etc/systemd/system/getty@tty1.service.d/override.conf << END
#[Service]
#Type=Simple
#ExecStart=
#ExecStart=-/usr/bin/agetty --autologin $user_name --noclear %I \$TERM
#END

echo "Hardening TCP/IP stack"
ufw default deny
ufw enable
systemctl enable ufw.service

tee -a /etc/sysctl.conf << END
# Configuration file for runtime kernel parameters.
# See sysctl.conf(5) for more information.

# Have the CD-ROM close when you use it, and open when you are done.
#dev.cdrom.autoclose = 1
#dev.cdrom.autoeject = 1

# Protection from the SYN flood attack. Matches Arch Wiki
net.ipv4.tcp_syncookies = 1

# See evil packets in your logs. Enabled as per Arch Wiki
net.ipv4.conf.all.log_martians = 1

# Never accept redirects or source routes (these are only useful for routers). Uncommented in as per Arch Wiki
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
#net.ipv6.conf.all.accept_redirects = 0
#net.ipv6.conf.all.accept_source_route = 0

# Disable packet forwarding. Matches Arch Wiki
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Tweak the port range used for outgoing connections.
#net.ipv4.ip_local_port_range = 32768 61000

# Tweak those values to alter disk syncing and swap behavior.
#vm.vfs_cache_pressure = 100
#vm.laptop_mode = 0
#vm.swappiness = 60

# Tweak how the flow of kernel messages is throttled.
#kernel.printk_ratelimit_burst = 10
#kernel.printk_ratelimit = 5

# Reboot 600 seconds after kernel panic or oops.
#kernel.panic_on_oops = 1
#kernel.panic = 600

# Arch Wiki
net.ipv4.tpc_rfc1337 = 1
net.ipv4.tcp_timestamps = 0 #Enable timestamps at gigabitspeeds
net.ipv4.conf.all.rp_filter = 1 #
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.secure_redirects = 1 #CentOS Wiki says 0 here.

#CentOS Wiki
net.ipv4.tcp_max_syn_backlog = 1280
END

#echo "Final application setup"
#wget https://raw.githubusercontent.com/kant5t1km3/archinstall/master/pkglist 
#pacman -Syu --noconfirm - < pkglist
#sudo systemctl enable --now lenovo_fix.service

# Exit arch-chroot
EOF

#umount -R /mnt
#swapoff -a

echo "Arch Linux is ready. You can reboot now!"
