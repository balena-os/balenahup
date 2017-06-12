#!/bin/bash

set -o errexit
set -o pipefail

. /etc/os-release

MIN_HOSTOS_VERSION=1.16.0
PREFERRED_HOSTOS_VERSION=1.27
DOCKER=docker

# Log function helper
function log {
    # Address log levels
    case $1 in
        ERROR)
            loglevel=ERROR
            shift
            ;;
        WARN)
            loglevel=WARNING
            shift
            ;;
        *)
            loglevel=LOG
            ;;
    esac
    ENDTIME=$(date +%s)
    if [ "z$LOG" == "zyes" ] && [ -n "$LOGFILE" ]; then
        printf "[%09d%s%s\n" "$(($ENDTIME - $STARTTIME))" "][$loglevel]" "$1" | tee -a $LOGFILE
    else
        printf "[%09d%s%s\n" "$(($ENDTIME - $STARTTIME))" "][$loglevel]" "$1"
    fi
    if [ "$loglevel" == "ERROR" ]; then
        /usr/bin/resin-device-progress --percentage 100 --state "ResinOS: Update failed."
        exit 1
    fi
}

# Test if a version is greater than another
function version_gt() {
    test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"
}

# Log timer
STARTTIME=$(date +%s)

# Check board support
case $SLUG in
    beaglebone*)
	TARGET_VERSION=2.0.6_rev2
	# In 2.x there is only a single device type
	DEVICE=beaglebone-black
	BINARY_TYPE=arm
	;;
    raspberry*)
	TARGET_VERSION=2.0.8_rev1
	DEVICE=$SLUG
	BINARY_TYPE=arm
	;;
    *)
	log ERROR "Unsupported board type $SLUG."
esac

# Check host OS version
if version_gt $VERSION $MIN_HOSTOS_VERSION || [ "$VERSION" == $MIN_HOSTOS_VERSION ]; then
    log "Host OS version $VERSION OK."
else
    case $VERSION in
	1.*)
	    log ERROR "Host OS version \"$VERSION\" too low, need \"$MIN_HOSTOS_VERSION\" or greater."
	    ;;
	*)
	    log ERROR "Host OS version \"$VERSION\" too high."
	    ;;
    esac
fi

# Check we are using the first root filesystem
root_part=$(findmnt -n --raw --evaluate --output=source /)
case $root_part in
    *p2)
	log "Current root partition is first root partition."
	;;
    *p3)
	log "Current root partition $root_part is the second root partition. Copying existing OS to first partition..."
	root_dev=${root_part%p3}
	dd if=${root_dev}p3 of=${root_dev}p2 bs=4M
	log "Updating bootloader to point to first partition..."
	case $SLUG in
	    beaglebone*)
		sed -i -e 's/bootpart=1:3/bootpart=1:2/' /mnt/boot/uEnv.txt
		;;
	    raspberry*)
		sed -i -e 's/mmcblk0p3/mmcblk0p2/' /mnt/boot/cmdline.txt
		;;
	esac
	log "Rebooting..."
	sync
	reboot
	;;
    *)
	log ERROR "Current root partition $root_part is not first or second root partition, aborting."
	;;
esac
root_dev=${root_part%p2}

# Check if we need to install some more extra tools
if ! version_gt $VERSION $PREFERRED_HOSTOS_VERSION && ! [ "$VERSION" == $PREFERRED_HOSTOS_VERSION ]; then
    log "Host OS version $VERSION is less than $PREFERRED_HOSTOS_VERSION, installing tools..."
    tools_path=/home/root/upgrade_tools
    tools_binaries="e2label mkfs.ext4 resize2fs tar"
    mkdir -p $tools_path
    export PATH=$tools_path:$PATH
    case $BINARY_TYPE in
	arm)
	    download_uri=https://github.com/resin-os/resinhup/raw/onetotwo/upgrade-binaries/$BINARY_TYPE
	    for binary in $tools_binaries; do
		log "Installing $binary..."
		curl -s -L -o $tools_path/$binary $download_uri/$binary
		chmod 755 $tools_path/$binary
	    done
	    ;;
	*)
	    log ERROR "Binary type $BINARY_TYPE not supported."
	    ;;
    esac
fi

# Stop docker containers
log "Stopping all containers..."
systemctl stop update-resin-supervisor.timer > /dev/null 2>&1
systemctl stop resin-supervisor > /dev/null 2>&1
$DOCKER stop $($DOCKER ps -a -q) > /dev/null 2>&1 || true
log "Removing all containers..."
$DOCKER rm $($DOCKER ps -a -q) > /dev/null 2>&1 || true
systemctl stop docker

# Switch connman to use bind mounted state dir
log "Switching connman to bind mounted state dir..."
mkdir -p /tmp/connman
cp -a /var/lib/connman/* /tmp/connman/
# Versions before 1.20 need this to prevent dropping VPN
sed -i -e 's/NetworkInterfaceBlacklist=docker,veth,tun,p2p/NetworkInterfaceBlacklist=docker,veth,tun,p2p,resin-vpn/' /etc/connman/main.conf
mount -o bind /tmp/connman /var/lib/connman
systemctl restart connman

# Save /resin-data to rootB
log "Making backup filesystem..."
mkfs.ext4 -F ${root_dev}p3
mkdir -p /tmp/backup
mount ${root_dev}p3 /tmp/backup
log "Backing up resin-data..."
(cd /mnt/data; tar -zcf /tmp/backup/resin-data.tar.gz resin-data)

# Unmount p6
log "Unmounting filesystems..."
umount /mnt/data
umount /var/lib/docker
umount /resin-data

# Save conf contents to /boot
# XXX

# Unmount p5 if mounted
if mount | grep /mnt/conf; then
    umount /mnt/conf
fi

# Unmount p1
umount /mnt/boot

log "Creating new partition table stage 1..."
# Delete partitions 4-6
parted -s $root_dev rm 6
parted -s $root_dev rm 5
parted -s $root_dev rm 4

# Desired layout:
# Partition	Size		Offset
# Primary	4MiB		0
# Boot		40MiB		4MiB
# RootA		312MiB		44MiB
# RootB		312MiB		356MiB
# Extended	Whole disk	668MiB
# Reserved	4MiB		668MiB
# State		20MiB		672MiB
# Reserved	4MiB		692MiB
# Data		Whole disk	696MiB

# Create extended partition
parted -s $root_dev mkpart extended 668MiB 100%

# Create state partition
parted -s $root_dev mkpart logical ext4 672MiB 692MiB

# Create data partition
# We're going to put btrfs on it initially but using type btrfs
# corrupts the partition table.
parted -s $root_dev mkpart logical ext4 696MiB 100%

log "Creating new state and data filesystems..."
# Create resin-state filesystem
mkfs.ext4 -F -L resin-state ${root_dev}p5

# Create resin-data filesystem
mkfs.btrfs -f -L resin-data ${root_dev}p6

# Remount data partition
mount ${root_dev}p6 /mnt/data

# Copy backup of resin-data
cp /tmp/backup/resin-data.tar.gz /mnt/data

# Unmount backup
umount /tmp/backup

log "Creating new partition table stage 2..."
parted -s $root_dev rm 3

# Resize partition 2 to desired size
# This uses sectors instead of MiB due to a bug in parted. Assumes 512b sectors
# https://debbugs.gnu.org/cgi/bugreport.cgi/cgi-bin/bugreport.cgi?bug=23511
parted -s $root_dev resizepart 2 729087s # 356MiB

# Create second root partition
parted -s $root_dev mkpart primary ext4 356MiB 668MiB

# Create filesystems now the partition table is migrated

log "Creating new root filesystems..."
# Resize first root partition
resize2fs ${root_dev}p2

# Create second root filesystem
mkfs.ext4 -F -L resin-rootB ${root_dev}p3

# Relabel first root filesystem
e2label ${root_dev}p2 resin-rootA

# Rescan partition labels
udevadm trigger

# Migrate state to resin-state partition
log "Creating resin-state partition based on existing config..."

# Mount state partition
mkdir -p /mnt/state
mount ${root_dev}p5 /mnt/state

# Touch reset file
touch /mnt/state/remove_me_to_reset

# Create /etc overlay
mkdir -p /mnt/state/root-overlay/etc

# Copy machine-id
cp -a /etc/machine-id /mnt/state/

# Copy hostname
cp -a /etc/hostname /mnt/state/root-overlay/etc

# Create some config dirs
mkdir -p /mnt/state/root-overlay/etc/systemd/system/resin.target.wants
mkdir -p /mnt/state/root-overlay/etc/resin-supervisor
mkdir -p /mnt/state/root-overlay/etc/NetworkManager/system-connections

# Create systemd files to start services
wants_dir=/mnt/state/root-overlay/etc/systemd/system/resin.target.wants
ln -s /lib/systemd/system/openvpn-resin.service $wants_dir
ln -s /lib/systemd/system/prepare-openvpn.service $wants_dir
ln -s /lib/systemd/system/resin-supervisor.service $wants_dir
ln -s /lib/systemd/system/update-resin-supervisor.timer $wants_dir

# Copy resin-supervisor config
cp -a /etc/supervisor.conf /mnt/state/root-overlay/etc/resin-supervisor

# resinOS 1.22 and 1.23 can have bad supervisor tags
sed -i -e 's/@TARGET_TAG@/v2.8.3/' /mnt/state/root-overlay/etc/resin-supervisor/supervisor.conf

# Copy docker config
mkdir -p /mnt/state/root-overlay/etc/docker
cp -a /etc/docker/* /mnt/state/root-overlay/docker

# Copy dropbear config
mkdir -p /mnt/state/root-overlay/etc/dropbear
cp -a /etc/dropbear/* /mnt/state/root-overlay/dropbear

# Create some /var dirs
mkdir -p /mnt/state/root-overlay/var/lib/systemd
mkdir -p /mnt/state/root-overlay/var/volatile/lib/systemd

# Copy systemd var files
cp -a /var/lib/systemd/* /mnt/state/root-overlay/var/lib/systemd

# Ensure /mnt/boot is mounted
mount ${root_dev}p1 /mnt/boot

# Migrate wifi config to NetworkManager
if grep service_home_wifi /mnt/boot/config.json >/dev/null; then
    # Get wifi credentials
    ssid=$(jq </mnt/boot/config.json '.["files"]."network/network.config"' | sed -e 's/.*Name = \([^\\"]*\).*/\1/')
    psk=$(jq </mnt/boot/config.json '.["files"]."network/network.config"' | sed -e 's/.*Passphrase = \([^\\"]*\).*/\1/')

    # Write NetworkManager setup
    cat >/mnt/state/root-overlay/etc/NetworkManager/system-connections/resin-wifi <<EOF
[connection]
id=resin-wifi
type=wifi

[wifi]
hidden=true
mode=infrastructure
ssid=$ssid

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$psk

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto
EOF
fi

# Make /root/.docker
mkdir -p /mnt/state/root-overlay/home/root/.docker

# Touch openssl rnd file
touch /mnt/state/root-overlay/home/root/.rnd

# Restart docker
log "Restarting docker..."
systemctl start docker

# Remount backup dir
mount ${root_dev}p3 /tmp/backup

IMAGE=resin/resinos:${TARGET_VERSION}-${DEVICE}
BACKUPARCHIVE=/tmp/backup/newos.tar.gz
FSARCHIVE=/mnt/data/newos.tar.gz

log "Getting new OS image..."
# Create container for new version
CONTAINER=$(docker create ${IMAGE} echo export)

# Export container
docker export ${CONTAINER} | gzip > ${BACKUPARCHIVE}

# Remove container
docker rm ${CONTAINER}

# Copy resin-data to backup partition before we wipe data
cp /mnt/data/resin-data.tar.gz /tmp/backup/

# Stop docker
systemctl stop docker

# Unmount data partition
umount /mnt/data
umount /var/lib/docker

# Make ext4 data partition
log "Creating new ext4 resin-data filesystem..."
mkfs.ext4 -F -L resin-data ${root_dev}p6

# Mount it
mount ${root_dev}p6 /mnt/data

# Copy resin-data backup and new OS to data partition
log "Restoring resin-data backup..."
(cd /mnt/data; tar xvf /tmp/backup/resin-data.tar.gz)
cp ${BACKUPARCHIVE} ${FSARCHIVE}

# Unmount backup dir
umount /tmp/backup

# Make new fs for rootB
log "Creating new root filesystem for new OS..."
mkfs.ext4 -F -L resin-rootB ${root_dev}p3

# Mount rootB partition
mkdir -p /tmp/rootB
mount ${root_dev}p3 /tmp/rootB

# Extract rootfs to rootB
log "Extracting new rootfs..."
echo quirks >/tmp/root-exclude
echo resin-boot >>/tmp/root-exclude
tar -x -X /tmp/root-exclude -C /tmp/rootB -f ${FSARCHIVE}

# Extract quirks
tar -x -C /tmp -f ${FSARCHIVE} quirks
cp -a /tmp/quirks/* /tmp/rootB/
rm -rf /tmp/quirks

# XXX hack required until 2.0.7 when a quirk is added for this
(cd /tmp/rootB/etc; rm mtab; ln -s ../proc/self/mounts mtab)

# Unmount rootB partition
umount /tmp/rootB

# Extract boot partition, exclude boot_whitelist files
log "Extracting new boot partition..."
echo resin-boot/cmdline.txt >/tmp/boot-exclude
echo resin-boot/config.txt >>/tmp/boot-exclude
echo resin-boot/splash/resin-logo.png >>/tmp/boot-exclude
echo resin-boot/uEnv.txt >>/tmp/boot-exclude
echo resin-boot/EFI/BOOT/grub.cfg >>/tmp/boot-exclude
# 2.x adds a default config.json, we should avoid clobbering the existing one
echo resin-boot/config.json >>/tmp/boot-exclude
tar -x -X /tmp/boot-exclude -C /tmp -f ${FSARCHIVE} resin-boot
cp -av /tmp/resin-boot/* /mnt/boot/

# Remove OS image
rm ${FSARCHIVE}

# Switch root partition
log "Switching root partition..."
case $SLUG in
    beaglebone*)
	echo 'resin_root_part=3' >/mnt/boot/resinOS_uEnv.txt
	sed -i -e '/mmcdev=.*/d' -e '/bootpart=.*/d' /mnt/boot/uEnv.txt
	;;
    raspberry*)
	sed -i -e 's/mmcblk0p2/mmcblk0p3/' /mnt/boot/cmdline.txt
	;;
esac

# Reboot into new OS
sync
log "Rebooting into new OS after 5 seconds ..."
sleep 5
reboot
