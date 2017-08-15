#!/bin/bash

NOREBOOT=no
STAGING=no

set -o errexit
set -o pipefail

preferred_hostos_version=2.0.7
minimum_target_version=2.0.7

# This will set VERSION, SLUG, and VARIANT_ID
. /etc/os-release

# Don't run anything before this source as it sets PATH here
source /etc/profile

###
# Helper functions
###

# Dashboard progress helper
function progress {
    percentage=$1
    message=$2
    resin-device-progress --percentage "${percentage}" --state "${message}" > /dev/null || true
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

  --no-reboot
        Do not reboot if update is successful. This is useful when debugging.

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

function stop_services() {
    # Stopping supervisor and related services
    log "Stopping supervisor and related services..."
    systemctl stop update-resin-supervisor.timer > /dev/null 2>&1
    systemctl stop resin-supervisor > /dev/null 2>&1
    docker stop resin_supervisor > /dev/null 2>&1 || true
}

function upgradeToReleaseSupervisor() {
    # Fetch what supervisor version the target hostOS was originally released with
    # and if it's newer than the supervisor running on the device, then fetch the
    # information that is required for supervisor update, then do the update with
    # the tools shipped with the hostOS.
    if [ "$STAGING" == "yes" ]; then
        DEFAULT_SUPERVISOR_VERSION_URL_BASE="https://s3.amazonaws.com/resin-staging-img/"
    else
        DEFAULT_SUPERVISOR_VERSION_URL_BASE="https://s3.amazonaws.com/resin-production-img-cloudformation/"
    fi
    # Convert the hostOS vesrsion into the format used for the resinOS storage buckets on S3
    # The '+' in the original version might have already been turnd into a '_', take that into account.
    HOSTOS_SLUG=$(echo "${target_version}" | sed -e 's/[_+]/%2B/' -e 's/$/.prod/')
    DEFAULT_SUPERVISOR_VERSION_URL="${DEFAULT_SUPERVISOR_VERSION_URL_BASE}images/${SLUG}/${HOSTOS_SLUG}/VERSION"

    # Get supervisor version for target resinOS release, it is in format of "va.b.c-shortsha", e.g. "v6.1.2"
    # and tag new version for the device if it's newer than the current version, from the API
    DEFAULT_SUPERVISOR_VERSION=$(curl -s "$DEFAULT_SUPERVISOR_VERSION_URL" | sed -e 's/v//')
    if [ -z "$DEFAULT_SUPERVISOR_VERSION" ] || [ -z "${DEFAULT_SUPERVISOR_VERSION##*xml*}" ]; then
        log ERROR "Could not get the default supervisor version for this resinOS release, bailing out."
    else
        CURRENT_SUPERVISOR_VERSION=$(curl -s "${API_ENDPOINT}/v2/device(${DEVICEID})?\$select=supervisor_version&apikey=${APIKEY}" | jq -r '.d[0].supervisor_version')
        if [ -z "$CURRENT_SUPERVISOR_VERSION" ]; then
            log ERROR "Could not get current supervisor version from the API, bailing out."
        else
            if version_gt "$DEFAULT_SUPERVISOR_VERSION" "$CURRENT_SUPERVISOR_VERSION" ; then
                log "Supervisor update: will be upgrading from v${CURRENT_SUPERVISOR_VERSION} to ${DEFAULT_SUPERVISOR_VERSION}"
                UPDATER_SUPERVISOR_TAG="v${DEFAULT_SUPERVISOR_VERSION}"
                # Get the supervisor id
                if UPDATER_SUPERVISOR_ID=$(curl -s "${API_ENDPOINT}/v2/supervisor_release?\$select=id,image_name&\$filter=((device_type%20eq%20'$SLUG')%20and%20(supervisor_version%20eq%20'$UPDATER_SUPERVISOR_TAG'))&apikey=${APIKEY}" | jq -e -r '.d[0].id'); then
                    log "Extracted supervisor vars: ID: $UPDATER_SUPERVISOR_ID"
                    log "Setting supervisor version in the API..."
                    curl -s "${API_ENDPOINT}/v2/device($DEVICEID)?apikey=$APIKEY" -X PATCH -H 'Content-Type: application/json;charset=UTF-8' --data-binary "{\"supervisor_release\": \"$UPDATER_SUPERVISOR_ID\"}" > /dev/null 2>&1
                    log "Running supervisor updater..."
                    progress 90 "ResinOS: running supervisor update..."
                    update-resin-supervisor
                    stop_services
                else
                    log WARN "Couldn't extract supervisor vars..."
                fi
            else
                log "Supervisor update: no update needed."
            fi
        fi
    fi
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
            target_version=$2
            shift
            ;;
        --no-reboot)
            NOREBOOT="yes"
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

if [ -z "$target_version" ]; then
    log ERROR "--hostos-version is required."
fi

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
    intel-nuc|up-board)
        binary_type=x86
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

# Check OS variant and filter update availability based on that.
if [ ! "$VARIANT_ID" == "prod" ]; then
    log ERROR "Only updating production devices..."
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
        x86)
            download_uri=https://github.com/imrehg/resinhup/raw/twototwo-fixes/upgrade-binaries/$binary_type
            for binary in $tools_binaries; do
                log "Installing $binary..."
                curl -f -s -L -o $tools_path/$binary $download_uri/$binary || log ERROR "Couldn't download tool from $download_uri/$binary, aborting."
                chmod 755 $tools_path/$binary
            done
            ;;
        "")
            log "No extra tooling fetched..."
            ;;
        *)
            log ERROR "Binary type $binary_type not supported."
            ;;
    esac
fi

log "Loading info from config.json"
if [ -f /mnt/boot/config.json ]; then
    CONFIGJSON=/mnt/boot/config.json
else
    log ERROR "Don't know where config.json is."
fi
APIKEY=$(jq -r '.deviceApiKey' $CONFIGJSON)
if [ "$APIKEY" == 'null' ]; then
    log WARN "Using apiKey as device does not have deviceApiKey yet..."
    APIKEY=$(jq -r '.apiKey' $CONFIGJSON)
fi
DEVICEID=$(jq -r '.deviceId' $CONFIGJSON)
API_ENDPOINT=$(jq -r '.apiEndpoint' $CONFIGJSON)

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
    *rootA)
        old_label=resin-rootA
        update_label=resin-rootB
        root_part_dev=$(blkid | grep "${old_label}" | awk '{print $1}' | sed 's/://')
        update_part=${root_part_dev%2}3
        ;;
    *rootB)
        old_label=resin-rootB
        update_label=resin-rootA
        root_part_dev=$(blkid | grep "${old_label}" | awk '{print $1}' | sed 's/://')
        update_part=${root_part_dev%2}3
        ;;
    *)
        log ERROR "Unknown root partition \"$root_part\"."
esac
if [ ! -b "$update_part" ]; then
    log ERROR "Update partition detected as ${update_part} but it's not a block device."
fi

# Stop docker containers
stop_services

image=resin/resinos:${target_version}-${SLUG}

log "Getting new OS image..."
progress 50 "ResinOS: downloading update package..."
# Create container for new version
container=$(docker create "$image" echo export)

progress 75 "ResinOS: running updater..."

log "Making new OS filesystem..."
# Format alternate root partition
log "Update partition: ${update_part}"
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
    intel-nuc|up-board)
        sed -i -e "s/${old_label}/${update_label}/" /mnt/boot/EFI/BOOT/grub.cfg
        ;;
esac

# Updating supervisor
upgradeToReleaseSupervisor

# Reboot into new OS
sync
if [ "$NOREBOOT" == "no" ]; then
    log "Rebooting into new OS in 5 seconds..."
    progress 100 "ResinOS: update successful, rebooting..."
    nohup bash -c " /bin/sleep 5 ; /sbin/reboot " > /dev/null 2>&1 &
else
    log "Finished update, not rebooting as requested."
    log "NOTE: Supervisor and stopped services kept stopped!"
    progress 100 "ResinOS: update successful."
fi
