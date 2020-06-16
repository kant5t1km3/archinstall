#!/bin/bash

encryption_passphrase=""
root_password=""
#user_password=""
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
blkdiscard /dev/nvme0n1
printf "o\nw\ny\n" | gdisk /dev/nvme0n1
printf "n\n1\n4096\n+512M\nef00\nw\ny\n" | gdisk /dev/nvme0n1
printf "n\n2\n\n\n8e00\nw\ny\n" | gdisk /dev/nvme0n1

#echo "Zeroing partitions"
#cat /dev/zero > /dev/nvme0n1p1
#cat /dev/zero > /dev/nvme0n1p2

echo "Setting up cryptographic volume"
modprobe dm-crypt
modprobe dm-mod
printf "%s" "$encryption_passphrase" | cryptsetup --use-random luksFormat /dev/nvme0n1p2
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
yes '' | pacstrap /mnt base base-devel linux linux-headers linux-lts linux-lts-headers linux-firmware lvm2 device-mapper e2fsprogs intel-ucode cryptsetup networkmanager wget man-db man-pages nano diffutils flatpak mkinitcpio vi vim reflector dhcpcd git sudo efibootmgr xf86-video-intel dialog wpa_supplicant pigz

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
sed -i 's/^HOOKS.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt sd-lvm2 filesystems fsck shutdown)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES.*/MODULES=(ext4 i915 lz4 lz4_compress)/' /etc/mkinitcpio.conf
sed -i 's/^BINARIES.*/BINARIES=(fsck fsck.ext4)/' /etc/mkinitcpio.conf
sed -i 's/#COMPRESSION="lz4"/COMPRESSION="lz4"/g' /etc/mkinitcpio.conf
sed -i 's/#COMPRESSION_OPTIONS=()/COMPRESSION_OPTIONS=(-9)/g' /etc/mkinitcpio.conf

mkinitcpio -p linux
mkinitcpio -p linux-lts

tee -a /etc/pacman.conf << END
[repo-ck]
Server = http://repo-ck.com/$arch
END
pacman-key -r 5EE46C4C && pacman-key --lsign-key 5EE46C4C
pacman -Sy linux-ck-skylake

echo "Setting up systemd-boot"
bootctl --path=/boot install

mkdir -p /boot/loader/
touch /boot/loader/loader.conf
tee -a /boot/loader/loader.conf << END
default archck
timeout 0
editor 0
END

mkdir -p /boot/loader/entries/

touch /boot/loader/entries/archck.conf
tee -a /boot/loader/entries/archck.conf << END
title Arch Linux CK
linux /vmlinuz-linux-ck
initrd /intel-ucode.img
initrd /initramfs-linux-ck.img
options rd.luks.name=$(blkid -s UUID -o value /dev/nvme0n1p2)=cryptlvm root=/dev/vg0/root resume=/dev/vg0/swap rd.luks.options=discard elevator=none i915.fastboot=1 i915.enable_psr=1 quiet loglevel=3 splash rw
END

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

echo "Do less swapping"
tee -a /etc/sysctl.d/99-swappiness.conf << END
vm.dirty_ratio = 6
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 1500
END

echo "Enabling periodic TRIM"
systemctl enable fstrim.timer

echo "Enabling Network Manager"
systemctl enable NetworkManager

echo "User Config"
echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo

wget https://raw.githubusercontent.com/brianclemens/dotfiles/011a080c6f5e87631623baf0aad826ff2b99566c/misc/sudoers.lecture
mv sudoers.lecture /etc/bee-sudoers.lecture
tee -a /etc/sudoers << END
Defaults    lecture=always
Defaults    lecture_file=/etc/bee-sudoers.lecture
END

curl -LO larbs.xyz/larbs.sh
sh larbs.sh
sed -i 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -z - --threads=0)/g' /etc/makepkg.conf
sed -i 's/COMPRESSGZ=(gzip -c -f -n)/COMPRESSGZ=(pigz -c -f -n)/g' /etc/makepkg.conf

echo "Setting autologin"
mkdir -p /etc/systemd/system/getty@tty1.service.d
tee -a /etc/systemd/system/getty@tty1.service.d/override.conf << END
[Service]
Type=Simple
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $user_name --noclear %I \$TERM
END

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

echo "Final application setup"
pacman -Syu --needed --noconfirm xorg-server xorg-xinit xorg-xrandr xf86-video-intel mesa libvirt ebtables dnsmasq bridge-utils virt-manager firefox zsh-completions wget curl transmission-cli tldr signal-desktop ffmpeg vlc rsync bleachbit neofetch man-db man-pages texinfo ufw clamav rkhunter util-linux tlp powertop throttled unzip unrar p7zip net-tools nmap xf86-input-libinput tree htop python go python-pip acpi whois speedtest-cli adb ntp strace tcpdump tcpreplay wireshark-qt clang cmake gdb
sudo systemctl enable --now lenovo_fix.service
yay -S slack-desktop spotify libreoffice codium-bin s-tui cava protonmail-bridge
sudo pip3 install somafm colorama requests

gpasswd -a $user_name libvirt
gpasswd -a $user_name kvm
systemctl enable libvirtd
systemctl start libvirtd

# Exit arch-chroot
EOF

umount -R /mnt
swapoff -a

echo "ArchLinux is ready. You can reboot now!"
