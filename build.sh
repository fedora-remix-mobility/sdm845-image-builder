#!/bin/bash

dnf -y install kiwi-cli android-tools git file

git clone https://github.com/fedora-remix-mobility/sdm845-images fedora-kiwi-descriptions
cd fedora-kiwi-descriptions
./kiwi-build --kiwi-file=Fedora-Mobility.kiwi --image-type=oem --image-profile=SDM845-Disk --output-dir ./outdir

cd outdir-build/
# In addition to u-boot which is flashed to boot_a and boot_b,
# we want to flash 3 partitions: op2 (sda7) - ESP, system_b (sda14) - /boot, userdata (sda17) - /
# lsblk -b on my OnePlus 6 (via UFS) gives the following sizes for those partitions in bytes:
# - sda7  -   268435456
# - sda14 -  2998927360
# - sda17 - 54132453376
# Let's ignore sda17 for now.
losetup -Pf Fedora-Mobility.aarch64-Rawhide.raw
# Sizes generated by the image are as follows:
# - loop0p1 -  524288000
# - loop0p2 - 1073741824
# So the UEFI partition needs to be resized. The /boot partition may stay as large as it is.
# We can resize it live later on if needed.
dd if=/dev/loop0p1 of=efipart.vfat bs=1M
truncate -s 268435456 newefipart.vfat
VOLID=$(file efipart.vfat | grep -Eo "serial number 0x.{8}" | cut -d\  -f3)
mkfs.vfat -F 32 -S 4096 -n EFI -i $VOLID newefipart.vfat
mkdir -p /mnt/a /mnt/b
mount -o loop efipart.vfat /mnt/a
mount -o loop newefipart.vfat /mnt/b
cp -a /mnt/a/* /mnt/b
umount /mnt/a /mnt/b

# Further modification on image:
dd if=/dev/loop0p2 of=bootpart.ext4 bs=1M
dd if=/dev/loop0p3 of=rootpart.btrfs bs=1M
losetup -d /dev/loop0

# Create a fake system root, because we want to mess with dracut
mkdir -p /mnt/system
mount -o loop,subvol=root rootpart.btrfs /mnt/system
mount -o loop,subvol=home rootpart.btrfs /mnt/system/home
mount -o loop,subvol=var rootpart.btrfs /mnt/system/var
mount -o loop bootpart.ext4 /mnt/system/boot
mount -o loop newefipart.vfat /mnt/system/boot/efi
mount --bind /sys /mnt/system/sys
mount --bind /proc /mnt/system/proc
mount --bind /dev /mnt/system/dev
mount --bind /sys/fs/selinux /mnt/system/sys/fs/selinux

# /!\ Use a different set of commands if you want to mount via UFS on a living device /!\
# Leaving that set of commands for reference
##mkdir -p /mnt/system
##mount -o subvol=root /dev/sda17 /mnt/system
##mount -o subvol=home /dev/sda17 /mnt/system/home
##mount -o subvol=var /dev/sda17 /mnt/system/var
##mount /dev/sda14 /mnt/system/boot
##mount /dev/sda7 /mnt/system/boot/efi
##mount --bind /sys /mnt/system/sys
##mount --bind /proc /mnt/system/proc
##mount --bind /dev /mnt/system/dev
##mount --bind /sys/fs/selinux /mnt/system/sys/fs/selinux
# /!\ End /!\

# Download firmwares:
git clone https://gitlab.com/sdm845-mainline/firmware-oneplus-sdm845

# Copy firmwares
cp --update -a firmware-oneplus-sdm845/usr /mnt/system/
cp --update -a firmware-oneplus-sdm845/lib /mnt/system/usr
# Hide ipa-fws.mbn. Somehow loading this firmware drops the phone into Crashdump mode
mv /mnt/system/usr/lib/firmware/qcom/sdm845/oneplus6/ipa_fws.mbn{,.disabled}

chroot /mnt/system /bin/bash <<'EOF'
  # Restore contexts for directories messed up by firmware upload
  restorecon -R -v /usr

  # Disable rghb and quiet for debugging (optional)
  sed -i 's/rhgb quiet//' /etc/default/grub
  grub2-mkconfig -o /etc/grub2-efi.cfg

  # Repart is segfaulting, so disable it
  rm -rf /usr/lib/dracut/modules.d/01systemd-repart # (repart is broken and hangs during boot, dunno why yet)
  rm -rf /etc/repart.d/*.conf

  # Regenerate initramfs with added modules
  KVER=$(ls /boot/config-* | tail -n1 | cut -d- -f2-)
  dracut -fv --kver=$KVER --no-hostonly

  # Not needed. Dracut in non-hostonly mode will take the modules required.
  ## echo 'add_drivers+=" ufs-qcom "' > /etc/dracut.conf.d/qcom-ufs.conf

  # Copy device tree so it can be picked by U-Boot instead of continuing to use U-Boot's one.
  # Not really needed, as the DTBs are synced anyway. But there may be some changes that
  # are downstream for certain devices.
  cp -a /boot/dtb/ /boot/efi/

  # Enable g_serial for serial debugging (unstable unfortunately)
  ## echo g_serial > /etc/modules-load.d/g_serial.conf
  ## systemctl enable serial-getty@ttyGS0.service

  # Change root password and add user account. Password is 147147 for both
  echo 'root:147147' | chpasswd
  groupadd -g 1000 user && \
    useradd -g 1000 -G wheel -m -u 1000 user && \
    echo 'user:147147' | chpasswd
  
  # Enable systemd services needed for driver functionality
  for i in bootmac-bluetooth.service hexagonrpcd-adsp-rootpd.service hexagonrpcd-adsp-sensorspd.service hexagonrpcd-sdsp.service pd-mapper.service rmtfs.service tqftpserv.service; do
    systemctl enable $i
  done

  # Change SELinux to permissive. Some issues still persist
  sed -i s/enforcing/permissive/g /etc/sysconfig/selinux

  # Add hexagonrpc config, so that sensor hardware drivers will know where to get
  # firmware from to initialize hardware.
  mkdir -p /usr/share/hexagonrpcd/
  echo 'hexagonrpcd_fw_dir="/usr/share/qcom/sdm845/OnePlus/oneplus6"' > /usr/share/hexagonrpcd/hexagonrpcd-sdsp.conf

  # Ensure relabel happens on firstboot. It will take some time and then a phone
  # will reboot.
  touch /.autorelabel
EOF

umount /mnt/system/sys/fs/selinux /mnt/system/sys /mnt/system/proc /mnt/system/dev /mnt/system/boot/efi /mnt/system/boot /mnt/system/var /mnt/system/home /mnt/system

mkdir -p out
img2simg newefipart.vfat out/Fedora-Remix-Mobility-EFI.simg
img2simg bootpart.ext4 out/Fedora-Remix-Mobility-BOOT.simg
img2simg rootpart.btrfs out/Fedora-Remix-Mobility-ROOT.simg

cat > out/flashall.sh <<'EOF'
  #!/bin/sh
  fastboot set_active b
  fastboot flash op2 Fedora-Remix-Mobility-EFI.simg
  fastboot flash system Fedora-Remix-Mobility-BOOT.simg
  fastboot flash userdata Fedora-Remix-Mobility-ROOT.simg
  echo "Success! Upload is ready, but you still must execute:"
  echo "  fastboot reboot"
  echo "Don't try to reboot manually, as the files may not be"
  echo "fully flashed yet."
EOF

chmod 0755 ./flashall.sh
