#!/bin/bash

set -o errexit
set -o pipefail

target_version=$1
preferred_hostos_version=2.0.7
minimum_target_version=2.0.7

# This will set VERSION and SLUG
. /etc/os-release

# Dashboard progress helper
function progress {
    percentage=$1
    message=$2
    /usr/bin/resin-device-progress --percentage ${percentage} --state "${message}" > /dev/null || true
}

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
    endtime=$(date +%s)
    if [ "z$LOG" == "zyes" ] && [ -n "$LOGFILE" ]; then
        printf "[%09d%s%s\n" "$((endtime - starttime))" "][$loglevel]" "$1" | tee -a "$LOGFILE"
    else
        printf "[%09d%s%s\n" "$((endtime - starttime))" "][$loglevel]" "$1"
    fi
    if [ "$loglevel" == "ERROR" ]; then
        progress 100 "ResinOS: Update failed."
        exit 1
    fi
}

# Test if a version is greater than another
function version_gt() {
    test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"
}

# Log timer
starttime=$(date +%s)

progress 25 "ResinOS: preparing update.."

# Check board support
case $SLUG in
    beaglebone*)
        binary_type=arm
        ;;
    raspberry*)
        binary_type=arm
        ;;
    *)
        log ERROR "Unsupported board type $SLUG."
esac

if [ -n "$target_version" ]; then
    case $target_version in
        2.*)
	    if ! version_gt "$target_version" "$minimum_target_version" &&
		    ! [ "$target_version" == "$minimum_target_version" ]; then
		log ERROR "Target OS version \"$target_version\" too low, please use \"$minimum_target_version\" or above."
	    else
		log "Target OS version \"$target_version\" OK."
	    fi
            ;;
        *)
            log ERROR "Target OS version \"$target_version\" not supported."
            ;;
    esac
else
    log ERROR "No target OS version specified."
fi

# Translate version to one docker will accept as part of an image name
target_version=$(echo "$target_version" | tr + _)

# Check host OS version
case $VERSION in
    2.*)
        log "Host OS version \"$VERSION\" OK."
        ;;
    *)
        log ERROR "Host OS version \"$VERSION\" not supported."
        ;;
esac

# Check if we need to install some more extra tools
if ! version_gt "$VERSION" "$preferred_hostos_version" &&
    ! [ "$VERSION" == "$preferred_hostos_version" ]; then
    log "Host OS version $VERSION is less than $preferred_hostos_version, installing tools..."
    tools_path=/tmp/upgrade_tools
    tools_binaries="tar"
    mkdir -p $tools_path
    export PATH=$tools_path:$PATH
    case $binary_type in
        arm)
            download_uri=https://github.com/resin-os/resinhup/raw/master/upgrade-binaries/$binary_type
            for binary in $tools_binaries; do
                log "Installing $binary..."
                curl -f -s -L -o $tools_path/$binary $download_uri/$binary || log ERROR "Couldn't download tool from $download_uri/$binary, aborting."
                chmod 755 $tools_path/$binary
            done
            ;;
        *)
            log ERROR "Binary type $binary_type not supported."
            ;;
    esac
fi

# Find which partition is / and which we should write the update to
root_part=$(findmnt -n --raw --evaluate --output=source /)
case $root_part in
    *p2)
        root_dev=${root_part%p2}
        update_part=${root_dev}p3
        update_part_no=3
        update_label=resin-rootB
        ;;
    *p3)
        root_dev=${root_part%p3}
        update_part=${root_dev}p2
        update_part_no=2
        update_label=resin-rootA
        ;;
    *)
        log ERROR "Unknown root partition \"$root_part\"."
esac

# Stop docker containers
log "Stopping all containers..."
systemctl stop update-resin-supervisor.timer > /dev/null 2>&1
systemctl stop resin-supervisor > /dev/null 2>&1
docker stop $(docker ps -a -q) > /dev/null 2>&1 || true

image=resin/resinos:${target_version}-${SLUG}

log "Getting new OS image..."
progress 50 "ResinOS: downloading update package..."
# Create container for new version
container=$(docker create "$image" echo export)

progress 75 "ResinOS: running updater..."

log "Making new OS filesystem..."
# Format alternate root partition
mkfs.ext4 -F -L "$update_label" "$update_part"

# Mount alternate root partition
mkdir -p /tmp/updateroot
mount "$update_part" /tmp/updateroot

# Extract rootfs
log "Extracting new rootfs..."
cat >/tmp/root-exclude <<EOF
quirks
resin-boot
EOF
docker export "$container" | tar -x -X /tmp/root-exclude -C /tmp/updateroot

# Extract quirks
docker export "$container" | tar -x -C /tmp quirks
cp -a /tmp/quirks/* /tmp/updateroot/
rm -rf /tmp/quirks

# Unmount alternate root partition
umount /tmp/updateroot

# Extract boot partition, exclude boot_whitelist files
log "Extracting new boot partition..."
cat >/tmp/boot-exclude <<EOF
resin-boot/cmdline.txt
resin-boot/config.txt
resin-boot/splash/resin-logo.png
resin-boot/uEnv.txt
resin-boot/EFI/BOOT/grub.cfg
resin-boot/config.json
EOF
docker export "$container" | tar -x -X /tmp/boot-exclude -C /tmp resin-boot
cp -a /tmp/resin-boot/* /mnt/boot/

# Clearing up
docker rm "$container"

# Switch root partition
log "Switching root partition..."
case $SLUG in
    beaglebone*)
	echo "resin_root_part=$update_part_no" >/mnt/boot/resinOS_uEnv.txt
	;;
    raspberry*)
	old_root=${root_part#/dev/}
	new_root=${update_part#/dev/}
	sed -i -e "s/$old_root/$new_root/" /mnt/boot/cmdline.txt
	;;
esac

# Reboot into new OS
sync
log "Rebooting into new OS..."
progress 100 "ResinOS: update successful, rebooting..."
reboot
