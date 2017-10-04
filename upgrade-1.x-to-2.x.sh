#!/bin/bash

NOREBOOT=no
STAGING=no
LOG=yes
SCRIPTNAME=upgrade-1.x-to-2.x.sh

set -o errexit
set -o pipefail

# This will set VERSION, SLUG, and VARIANT_ID
. /etc/os-release

# Don't run anything before this source as it sets PATH here
source /etc/profile

MIN_HOSTOS_VERSION=1.8.0
PREFERRED_HOSTOS_VERSION=1.27
DOCKER=docker

# Log timer
STARTTIME=$(date +%s)

###
# Helper functions
###

# Dashboard progress helper
function progress {
    percentage=$1
    message=$2
    # Progress bar is "nice to have", but might fail on some systems.
    # Try the default call, if that fails try the call with the updated config.json location,
    # if that fails too then just give up and do not display a progress update
    /usr/bin/resin-device-progress --percentage ${percentage} --state "${message}" > /dev/null || /usr/bin/resin-device-progress --config-path "/boot/config.json" --percentage ${percentage} --state "${message}" > /dev/null || true
}

function help {
    cat << EOF
Helper to run hostOS updates on resinOS 2.x devices

Options:
  -h, --help
        Display this help and exit.

  --hostos-version <HOSTOS_VERSION>
        Run the updater for this specific HostOS version as semver.
        Omit the 'v' in front of the version. e.g.: 2.2.0+rev1 and not v2.2.0+rev1.
        This is a mandatory argument.

  --supervisor-version <SUPERVISOR_VERSION>
        Run the supervisor update for this specific supervisor version as semver.
        Omit the 'v' in front of the version. e.g.: 6.2.5 and not v6.2.5
        If not defined, then the update will try to run for the HOSTOS_VERSION's
        original supervisor release.

  --no-reboot
        Do not reboot if update is successful. This is useful when debugging.

  -n, --nolog
        By default tool logs to stdout and file. This flag deactivates log to file.

  --staging
        Get information from the resin staging environment as opposed to production.
EOF
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
    ENDTIME=$(date +%s)
    if [ "z$LOG" == "zyes" ] && [ -n "$LOGFILE" ]; then
        printf "[%09d%s%s\n" "$(($ENDTIME - $STARTTIME))" "][$loglevel]" "$1" | tee -a $LOGFILE
    else
        printf "[%09d%s%s\n" "$(($ENDTIME - $STARTTIME))" "][$loglevel]" "$1"
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

function upgradeSupervisor() {
    # Fetch what supervisor version the target hostOS was originally released with
    # and if it's newer than the supervisor running on the device, then fetch the
    # information that is required for supervisor update, then do the update with
    # the tools shipped with the hostOS.
    log "Supervisor update start..."

    if [ -z "$TARGET_SUPERVISOR_VERSION" ]; then
        log "No explicit supervisor version was provided, update to default version in target resinOS..."
        if [ "$STAGING" = "yes" ]; then
            DEFAULT_SUPERVISOR_VERSION_URL_BASE="https://s3.amazonaws.com/resin-staging-img/"
        else
            DEFAULT_SUPERVISOR_VERSION_URL_BASE="https://s3.amazonaws.com/resin-production-img-cloudformation/"
        fi
        # Convert the hostOS vesrsion into the format used for the resinOS storage buckets on S3
        # The '+' in the original version might have already been turnd into a '_', take that into account.
        HOSTOS_SLUG=$(echo "${TARGET_VERSION}" | sed -e 's/[_+]/%2B/' -e 's/$/.prod/')
        DEFAULT_SUPERVISOR_VERSION_URL="${DEFAULT_SUPERVISOR_VERSION_URL_BASE}images/${SLUG}/${HOSTOS_SLUG}/VERSION"

        # Get supervisor version for target resinOS release, it is in format of "va.b.c-shortsha", e.g. "v6.1.2"
        # and tag new version for the device if it's newer than the current version, from the API
        DEFAULT_SUPERVISOR_VERSION=$(curl -s "$DEFAULT_SUPERVISOR_VERSION_URL" | sed -e 's/v//')
        if [ -z "$DEFAULT_SUPERVISOR_VERSION" ] || [ -z "${DEFAULT_SUPERVISOR_VERSION##*xml*}" ]; then
            log ERROR "Could not get the default supervisor version for this resinOS release, bailing out."
        else
            TARGET_SUPERVISOR_VERSION="$DEFAULT_SUPERVISOR_VERSION"
        fi
    fi

    if CURRENT_SUPERVISOR_VERSION=$(curl -s "${API_ENDPOINT}/v2/device(${DEVICEID})?\$select=supervisor_version&apikey=${APIKEY}" | jq -r '.d[0].supervisor_version'); then
        if [ -z "$CURRENT_SUPERVISOR_VERSION" ]; then
            log ERROR "Could not get current supervisor version from the API..."
        else
            if version_gt "$TARGET_SUPERVISOR_VERSION" "$CURRENT_SUPERVISOR_VERSION" ; then
                log "Supervisor update: will be upgrading from v${CURRENT_SUPERVISOR_VERSION} to ${TARGET_SUPERVISOR_VERSION}"
                UPDATER_SUPERVISOR_TAG="v${TARGET_SUPERVISOR_VERSION}"
                # Get the supervisor id, which is the unique numerical key of the supervisor version for the given device type
                if UPDATER_SUPERVISOR_ID=$(curl -s "${API_ENDPOINT}/v2/supervisor_release?\$select=id,image_name&\$filter=((device_type%20eq%20'$SLUG')%20and%20(supervisor_version%20eq%20'$UPDATER_SUPERVISOR_TAG'))&apikey=${APIKEY}" | jq -e -r '.d[0].id'); then
                    log "Extracted supervisor vars: ID: $UPDATER_SUPERVISOR_ID"
                    log "Setting supervisor version in the API..."
                    curl -s "${API_ENDPOINT}/v2/device($DEVICEID)?apikey=$APIKEY" -X PATCH -H 'Content-Type: application/json;charset=UTF-8' --data-binary "{\"supervisor_release\": \"$UPDATER_SUPERVISOR_ID\"}" > /dev/null 2>&1
                    log "Updating local configuration at ${supervisor_conf_path}..."
                    if grep -q "SUPERVISOR_TAG" "${supervisor_conf_path}"; then
                        # Update supervisor tag
                        sed -i -e 's/SUPERVISOR_TAG=.*/SUPERVISOR_TAG='"${UPDATER_SUPERVISOR_TAG}"'/' "${supervisor_conf_path}"
                    else
                        # Insert supervisor tag
                        echo "SUPERVISOR_TAG=${UPDATER_SUPERVISOR_TAG}" >> "${supervisor_conf_path}"
                    fi
                    # Remove staging registry from the config
                    sed -i -e 's/SUPERVISOR_IMAGE=registry.resinstaging.io\//SUPERVISOR_IMAGE=/' "${supervisor_conf_path}"
                    log "Supervisor config update done."
                else
                    log ERROR "Couldn't extract supervisor vars..."
                fi
            else
                log "Supervisor update: no update needed."
            fi
        fi
    else
        log WARN "Could not parse current supervisor version from the API, skipping update..."
    fi
}

function wifi_migrate() {
    # Function to create simple NetworkManager configuration files
    # from the given SSID and password values
    local path=$1
    local wifi_config_name=$2
    local ssid=$3
    local psk=$4

    # Write NetworkManager setup
    cat >"${path}/system-connections/${wifi_config_name}" <<EOF
[connection]
id=$wifi_config_name
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
}

function stop_all() {
    # Stop supervisor and docker
    log "Stopping all containers..."
    systemctl stop update-resin-supervisor.timer > /dev/null 2>&1
    systemctl stop resin-supervisor > /dev/null 2>&1
    $DOCKER stop $($DOCKER ps -a -q) > /dev/null 2>&1 || true
    log "Removing all containers..."
    $DOCKER rm $($DOCKER ps -a -q) > /dev/null 2>&1 || true
    log "Stopping $DOCKER"
    systemctl stop docker
}

###
# Script start
###

# Parse arguments
while [[ $# -gt 0 ]]; do
    arg="$1"

    case $arg in
        -h|--help)
            help
            exit 0
            ;;
        --hostos-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            TARGET_VERSION=$2
            shift
            ;;
        --supervisor-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            TARGET_SUPERVISOR_VERSION=$2
            shift
            ;;
        --no-reboot)
            NOREBOOT="yes"
            ;;
        -n|--nolog)
            LOG=no
            ;;
        --staging)
            STAGING="yes"
            ;;
        *)
            log ERROR "Unrecognized option $1."
            ;;
    esac
    shift
done

# LOGFILE init and header
if [ "$LOG" == "yes" ]; then
    LOGFILE="/tmp/$SCRIPTNAME.$(date +"%Y%m%d_%H%M%S").log"
    mkdir -p "$(dirname "$LOGFILE")"
    echo "================$SCRIPTNAME HEADER START====================" > "$LOGFILE"
    date >> "$LOGFILE"
fi

if [ -z ${TARGET_VERSION+x} ]; then
    log ERROR "--hostos-version is required."
fi

progress 5 "ResinOS: update preparation..."

# Check board support
case $SLUG in
    beaglebone*)
        MIN_TARGET_VERSION=2.2.0+rev1
        # In 2.x there is only a single device type
        DEVICE=beaglebone-black
        BINARY_TYPE=arm
        ;;
    raspberry*)
        MIN_TARGET_VERSION=2.2.0+rev1
        DEVICE=$SLUG
        BINARY_TYPE=arm
        ;;
    *)
        log ERROR "Unsupported board type $SLUG."
esac

# Check starting host OS version
if version_gt $VERSION $MIN_HOSTOS_VERSION || [ "$VERSION" == $MIN_HOSTOS_VERSION ]; then
    log "Starting Host OS version $VERSION OK."
else
    case $VERSION in
	1.*)
	    log ERROR "Starting Host OS version \"$VERSION\" too low, need \"$MIN_HOSTOS_VERSION\" or greater."
	    ;;
	*)
	    log ERROR "Starting Host OS version \"$VERSION\" too high."
	    ;;
    esac
fi

# Check target host OS version
if version_gt $TARGET_VERSION $MIN_TARGET_VERSION || [ "$TARGET_VERSION" == $MIN_TARGET_VERSION ]; then
    log "Target Host OS version $TARGET_VERSION OK."
else
    log ERROR "Target Host OS version \"$TARGET_VERSION\" too low, need \"$MIN_TARGET_VERSION\" or greater."
fi

# Translate version to one docker will accept as part of an image name
TARGET_VERSION=$(echo "$TARGET_VERSION" | tr + _)

# Find boot path
boot_path=$(findmnt -n --raw --evaluate --output=target LABEL=resin-boot)
if [ -z "${boot_path}" ]; then
    log ERROR "Cannot find where is 'resin-boot' mounted"
else
    log "Boot partition is mounted at ${boot_path}."
fi

# Check we are using the first root filesystem
root_part=$(findmnt -n --raw --evaluate --output=source /)
case $root_part in
    *p2)
        log "Current root partition is first root partition."
        ;;
    *p3)
        log "Current root partition $root_part is the second root partition. Copying existing OS to first partition..."
        progress 10 "ResinOS: partition switching..."
        stop_all
        sync
        log "Forcing remount of file systems in read-only mode..."
        echo u > /proc/sysrq-trigger
        log "Copying current root partition to the unused partiton..."
        root_dev=${root_part%p3}
        dd if=${root_dev}p3 of=${root_dev}p2 bs=4M
        log "Remounting boot partition as rw for the next step..."
        mount -o remount,rw "${boot_path}"
        log "Updating bootloader to point to first partition..."
        case $SLUG in
            beaglebone*)
                sed -i -e 's/bootpart=1:3/bootpart=1:2/' "${boot_path}/uEnv.txt"
                ;;
            raspberry*)
                sed -i -e 's/mmcblk0p3/mmcblk0p2/' "${boot_path}/cmdline.txt"
                ;;
        esac
        log "Rebooting..."
        progress 15 "ResinOS: rebooting to continue..."
        sync
        nohup bash -c " /bin/sleep 5 ; /sbin/reboot " > /dev/null 2>&1 &
        exit 0
        ;;
    *)
        log ERROR "Current root partition $root_part is not first or second root partition, aborting."
        ;;
esac
root_dev=${root_part%p2}

progress 25 "ResinOS: system preparation..."

# Check if we need to install some more extra tools
if ! version_gt $VERSION $PREFERRED_HOSTOS_VERSION && ! [ "$VERSION" == $PREFERRED_HOSTOS_VERSION ]; then
    log "Host OS version $VERSION is less than $PREFERRED_HOSTOS_VERSION, installing tools..."
    tools_path=/home/root/upgrade_tools
    tools_binaries="e2label mkfs.ext4 resize2fs tar"
    mkdir -p $tools_path
    export PATH=$tools_path:$PATH
    case $BINARY_TYPE in
	arm)
	    download_uri=https://github.com/resin-os/resinhup/raw/master/upgrade-binaries/$BINARY_TYPE
	    for binary in $tools_binaries; do
		log "Installing $binary..."
		curl -f -s -L -o $tools_path/$binary $download_uri/$binary || log ERROR "Couldn't download tool from $download_uri/$binary, aborting."
		chmod 755 $tools_path/$binary
	    done
	    ;;
	*)
	    log ERROR "Binary type $BINARY_TYPE not supported."
	    ;;
    esac
fi

# Loading useful variables
if [ -f /mnt/boot/config.json ]; then
    CONFIGJSON=/mnt/boot/config.json
elif [ -f /mnt/conf/config.json ]; then
    CONFIGJSON=/mnt/conf/config.json
elif [ -f /mnt/data-disk/config.json ]; then
    CONFIGJSON=/mnt/data-disk/config.json
else
    log ERROR "Don't know where config.json is."
fi
APIKEY=$(jq -r .apiKey $CONFIGJSON)
DEVICEID=$(jq -r .deviceId $CONFIGJSON)
API_ENDPOINT=$(jq -r .apiEndpoint $CONFIGJSON)
# Get App ID from the API to get the current value, since the device might have been moved from the originally provisioned application
APP_ID=$(curl -s "${API_ENDPOINT}/v2/application?\$filter=device/id%20eq%20${DEVICEID}&apikey=${APIKEY}" -H "Content-Type: application/json" | jq .d[0].id)

# Stop docker containers
stop_all

# Switch connman to use bind mounted state dir
log "Switching connman to bind mounted state dir..."
mkdir -p /tmp/connman
cp -a /var/lib/connman/* /tmp/connman/
# Versions before 1.20 need this to prevent dropping VPN
sed -i -e 's/NetworkInterfaceBlacklist=docker,veth,tun,p2p/NetworkInterfaceBlacklist=docker,veth,tun,p2p,resin-vpn/' /etc/connman/main.conf
mount -o bind /tmp/connman /var/lib/connman
# some systems require daemon-reload to correctly restart connman later
systemctl daemon-reload
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
if [ -f "/mnt/conf/config.json" ]; then
    # the boot partition might be mounted ro on some systems, remount
    mount -o remount,rw "${boot_path}"
    cp "/mnt/conf/config.json" "${boot_path}/config.json"
fi

# Unmount p5 if mounted
if mount | grep /mnt/conf; then
    umount /mnt/conf
fi

# Unmount p1
umount "${boot_path}"

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

supervisor_conf_path="/mnt/state/root-overlay/etc/resin-supervisor/supervisor.conf"
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

# Ensure that the boot partition is mounted
mount ${root_dev}p1 "${boot_path}"

# Make /root/.docker
mkdir -p /mnt/state/root-overlay/home/root/.docker

# Touch openssl rnd file
touch /mnt/state/root-overlay/home/root/.rnd

# Restart docker
log "Restarting docker..."
systemctl start docker

# Remount backup dir
mount ${root_dev}p3 /tmp/backup

if [ "$STAGING" = "yes" ]; then
    IMAGE=resin/resinos-staging:${TARGET_VERSION}-${DEVICE}
else
    IMAGE=resin/resinos:${TARGET_VERSION}-${DEVICE}
fi
log "Using resinOS image: ${IMAGE}"

BACKUPARCHIVE=/tmp/backup/newos.tar.gz
FSARCHIVE=/mnt/data/newos.tar.gz

log "Getting new OS image..."
progress 50 "ResinOS: downloading OS update..."
# Create container for new version
CONTAINER=$(docker create ${IMAGE} echo export)

progress 60 "ResinOS: processig update package..."
# Export container
log "Starting docker export"
docker export ${CONTAINER} | gzip > ${BACKUPARCHIVE}

# Remove container
log "Removing container"
docker rm ${CONTAINER}

# Copy resin-data to backup partition before we wipe data
log "Copy resin-data to backup partition"
cp /mnt/data/resin-data.tar.gz /tmp/backup/

# Stop docker
log "Stopping docker"
systemctl stop docker

# Unmount data partition
umount /mnt/data
umount /var/lib/docker

progress 75 "ResinOS: running updater..."

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
cp -av /tmp/resin-boot/* "${boot_path}"

# Remove OS image
rm ${FSARCHIVE}

# Migrate wifi config to NetworkManager
if grep service_home_wifi "${boot_path}/config.json" >/dev/null; then
    # Get wifi credentials
    ssid=$(jq <${boot_path}/config.json '.["files"]."network/network.config"' | sed -e 's/.*Name = \([^\\"]*\).*/\1/')
    psk=$(jq <${boot_path}/config.json '.["files"]."network/network.config"' | sed -e 's/.*Passphrase = \([^\\"]*\).*/\1/')

    # Write NetworkManager setup
    wifi_migrate "$boot_path" "resin-wifi" "$ssid" "$psk"
fi
# Migrate resin-wifi-connect settings if found
if [ -n "$APP_ID" ] && [ -f "/mnt/data/resin-data/${APP_ID}/network.config" ]; then
    wifi_connect_config_file="/mnt/data/resin-data/${APP_ID}/network.config"
    log "Found likely resin-wifi-connect network config at ${wifi_connect_config_file}, migrating..."

    # Need to pre-check the existence of the wifi settings, otherwise grep will fail silently
    # in the ssid/psk extraction step, breaking the script.
    if grep service_home_wifi "$wifi_connect_config_file" >/dev/null; then
        ssid=$(cat "${wifi_connect_config_file}" |grep "service_home_wifi" -A 5 | sed -n -e 's/.*Name = \([^\\"]*\).*/\1/p')
        psk=$(cat "${wifi_connect_config_file}" |grep "service_home_wifi" -A 5 | sed -n -e 's/.*Passphrase = \([^\\"]*\).*/\1/p')

        if [ -z "$ssid" ]; then
            log "No SSID setting found, not migrating settings..."
        else
            wifi_migrate "$boot_path" "resin-wifi-connect" "$ssid" "$psk"
        fi
    else
        log "No wifi settings seem to be present in ${wifi_connect_config_file}..."
    fi
fi

# Switch root partition
log "Switching root partition..."
case $SLUG in
    beaglebone*)
        echo 'resin_root_part=3' >"${boot_path}/resinOS_uEnv.txt"
        sed -i -e '/mmcdev=.*/d' -e '/bootpart=.*/d' "${boot_path}/uEnv.txt"
        ;;
    raspberry*)
        sed -i -e 's/mmcblk0p2/mmcblk0p3/' "${boot_path}/cmdline.txt"
        ;;
esac

# Upgrade supervisor in the API and in the config
upgradeSupervisor
# Remove stale supervisor database, so it will be recreated from scratch
rm -rf /mnt/data/resin-data/resin-supervisor

sync
if [ "$NOREBOOT" == "no" ]; then
    # Reboot into new OS
    log "Rebooting into new OS in 5 seconds..."
    progress 100 "ResinOS: update successful, rebooting..."
    nohup bash -c " /bin/sleep 5 ; /sbin/reboot " > /dev/null 2>&1 &
else
    log "Finished update, not rebooting as requested."
    log "NOTE: Supervisor and stopped services kept stopped!"
    progress 100 "ResinOS: update successful."
fi
