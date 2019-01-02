#!/usr/bin/env bash
set -e
set -o pipefail

BOOT=${1:-/boot}
IRFS_HOOK="/etc/initramfs-tools/hooks/acpi_override.sh"
cd `mktemp -d`

###
# If the tested version of iasl is not currently installed...
if [ "$(iasl -v | grep -c 20181031)" -eq 0 ]; then
 
 echo "[*] Attempting to install required tools to build iasl"
 
 # Build a newer version of iasl
 # If on Debian-based distro...
 if [ -x "$(which apt-get)" ]; then
     sudo apt-get -y install bison flex
 # If on Arch-based distro...
 elif [ -x "$(which pacman)" ]; then
     sudo pacman -S bison flex
 else
     echo "Unable to automatically download and install bison or flex"
     echo "Manual install needed"
     exit 1
 fi

 echo "[*] Upgrading IASL..."
 wget https://acpica.org/sites/acpica/files/acpica-unix2-20181031.tar.gz 
 tar -zxf acpica-unix2-20181031.tar.gz
 cd acpica-unix2-20181031
 make clean
 make iasl || { echo 'ERROR: Failed to build IASL' ; exit 1; }
 sudo make install || { echo 'ERROR: Failed to install new version of IASL' ; exit 1; }
 cd ..
fi
###

###
# Make sure we have required tools on systems with apt
echo "[*] Attempting to install required tools"

# If on Debian-based distro...
if [ -x "$(which apt-get)" ]; then
    sudo apt-get -y install cpio

# If on Arch-based distro...
elif [ -x "$(which pacman)" ]; then
    echo "[*] Installing Yay to be able to download AUR packages"
    if ![ -x "$(which git)" ]; then
        sudo pacman -S git
    fi
    if ![ -x "$(which yay)" ]; then
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si
    fi
    echo "Installing cpio"
    yay -Syu cpio
fi
###

# extract dsdt
echo "[*] Dumping DSDT"
sudo cat /sys/firmware/acpi/tables/DSDT > dsdt.dat

# decompile
echo "[*] Decompiling DSDT"
iasl -d dsdt.dat
cp dsdt.dsl dsdt.dsl.orig
echo "[*] Patching DSDT"
cat dsdt.dsl |
  tr '\n' '\r' |
  sed -e 's|DefinitionBlock ("", "DSDT", 2, "LENOVO", "SKL     ", 0x00000000)|DefinitionBlock ("", "DSDT", 2, "LENOVO", "SKL     ", 0x00000001)|' \
      -e 's|Name (SS3, One)\r    One\r    Name (SS4, One)\r    One|Name (SS3, One)\r    Name (SS4, One)|' \
      -e 's|\_SB.SGOV (DerefOf (Arg0 \[0x02\]), (DerefOf (Arg0 \[0x03\]) ^ \r                            0x01))|\_SB.SGOV (DerefOf (Arg0 [0x02]), (DerefOf (Arg0 [0x03]) ^ 0x01))|' \
      -e 's|    Name (\\\_S4, Package (0x04)  // _S4_: S4 System State|    Name (\\\_S3, Package (0x04)  // _S3_: S3 System State\r    {\r        0x05,\r        0x05,\r        0x00,\r        0x00\r    })\r    Name (\\\_S4, Package (0x04)  // _S4_: S4 System State|' |
  tr '\r' '\n' > dsdt_patched.dsl

mv dsdt_patched.dsl dsdt.dsl

# compile
echo "[*] Compiling DSDT"
iasl -tc -ve dsdt.dsl

# generate override
echo "[*] Generating acpi_override"
mkdir -p kernel/firmware/acpi
cp dsdt.aml kernel/firmware/acpi
find kernel | cpio -H newc --create > acpi_override

# copy override file to boot partition
sudo cp acpi_override ${BOOT} || \
	{ echo "ERROR: Could not copy acpi_override"; exit $?; }

# check if we have initramfs and prepend our stuff
if [ -d $(dirname "${IRFS_HOOK}") ] && [ -x $(which update-initramfs) ]; then
	echo "[*] Adding hook to initramfs"
	sudo bash -c "cat > ${IRFS_HOOK} <<- HOOK
	#!/bin/sh
	. /usr/share/initramfs-tools/hook-functions
	prepend_earlyinitramfs /boot/acpi_override
	HOOK"
	sudo chmod +x ${IRFS_HOOK}
	sudo update-initramfs -u -k all
	echo "[*] Done!"
else
    echo "Done! Don't forget to update your bootloader config."
fi
