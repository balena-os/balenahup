#!/bin/bash

# default configuration
NOREBOOT=no
LOG=yes
IGNORE_SANITY_CHECKS=no
RESINOS_REGISTRY="registry.hub.docker.com"
RESINOS_REPO="resin/resinos"
SCRIPTNAME=upgrade-2.x.sh
LEGACY_UPDATE=no
STOP_ALL=no

set -o errexit
set -o pipefail

preferred_hostos_version=2.0.7
minimum_target_version=2.0.7
minimum_hostapp_target_version=2.5.1
minimum_balena_target_version=2.9.0

# This will set VERSION, SLUG, and VARIANT_ID
. /etc/os-release

# Don't run anything before this source as it sets PATH here
source /etc/profile

if [ -x "$(command -v balena)" ]; then
    DOCKER_CMD="balena"
    DOCKERD="balenad"
else
    DOCKER_CMD="docker"
    DOCKERD="dockerd"
fi

###
# Helper functions
###

# Preventing running multiple instances of upgrades running
LOCKFILE="/var/lock/resinhup.lock"
LOCKFD=99
## Private functions
_lock()             { flock "-$1" $LOCKFD; }
_no_more_locking()  { _lock u; _lock xn && rm -f $LOCKFILE; }
_prepare_locking()  { eval "exec $LOCKFD>\"$LOCKFILE\""; trap _no_more_locking EXIT; }
# Public functions
exlock_now()        { _lock xn; }  # obtain an exclusive lock immediately or fail

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

  --force-slug <SLUG>
        Override slug detection and force this slug to be used for the script.

  --hostos-version <HOSTOS_VERSION>
        Run the updater for this specific HostOS version as semver.
        Omit the 'v' in front of the version. e.g.: 2.2.0+rev1 and not v2.2.0+rev1.
        This is a mandatory argument.

  --supervisor-version <SUPERVISOR_VERSION>
        Run the supervisor update for this specific supervisor version as semver.
        Omit the 'v' in front of the version. e.g.: 6.2.5 and not v6.2.5
        If not defined, then the update will try to run for the HOSTOS_VERSION's
        original supervisor release.

    -n, --nolog
        By default tool logs to stdout and file. This flag deactivates log to file.

  --no-reboot
        Do not reboot if update is successful. This is useful when debugging.

  --resinos-registry <REGISTRY>
        The docker registry where to look for the resinOS image. If not defined,
        it will default to Docker Hub (registry.hub.docker.com)

  --resinos-repo <REPOSITORY>
        The docker repository where to pull the resinOS image from. Defaults to
        'resin/resinos'.

  --resinos-tag <TAG>
        This flag overrides the default tag, which is based on host OS version
        and slug, when looking for the resinOS image to use for the update.

  --staging
        This is deprecated, use --resinos-repo <REPOSITORY>
        For backwards compatibility, this flag acts the same as
        --resinos-repo resin/resinos-staging

  --stop-all
        Request the updater to stop all containers (including user application)
        before the update.

  --ignore-sanity-checks
        The update scripts runs a number of sanity checks on the device, whether or not
        it is safe to update (e.g. device type and running system cross checks)
        This flags turns sanity check failures from errors into warnings only, so the
        the update is not stopped if there are any failures.
        Use with extreme caution!
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
    printf "[%09d%s%s\n" "$((endtime - starttime))" "][$loglevel]" "$1"
    if [ "$loglevel" == "ERROR" ]; then
        progress 100 "OS update failed"
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
    ${DOCKER_CMD} stop resin_supervisor > /dev/null 2>&1 || true
}

function remove_containers() {
    log "Stopping all containers.."
    # shellcheck disable=SC2046
    ${DOCKER_CMD} stop $(${DOCKER_CMD} ps -a -q) > /dev/null 2>&1 || true
    log "Removing all containers..."
    # shellcheck disable=SC2046
    ${DOCKER_CMD} rm $(${DOCKER_CMD} ps -a -q) > /dev/null 2>&1 || true
}

#######################################
# Upgrade the supervisor on the device.
# Extract the supervisor version with which the the target hostOS is shipped,
# and if it's newer than the supervisor running on the device, then fetch the
# information that is required for supervisor update, and do the update with
# the tools shipped with the hostOS.
# Globals:
#   API_ENDPOINT
#   APIKEY
#   DEVICEID
#   SLUG
#   target_supervisor_version
# Arguments:
#   image: the docker image to exctract the config from
#   non_docker_host: empty value will use docker-host, non empty value will use the main docker
# Returns:
#   None
#######################################
function upgrade_supervisor() {
    local image=$1
    local no_docker_host=$2
    log "Supervisor update start..."

    if [ -z "$target_supervisor_version" ]; then
        log "No explicit supervisor version was provided, update to default version in target resinOS..."
        local DEFAULT_SUPERVISOR_VERSION
        versioncheck_cmd=("run" "--rm" "${image}" "bash" "-c" "cat /etc/resin-supervisor/supervisor.conf | sed -rn 's/SUPERVISOR_TAG=v(.*)/\\1/p'")
        if [ -z "$no_docker_host" ]; then
            DEFAULT_SUPERVISOR_VERSION=$(DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} "${versioncheck_cmd[@]}")
        else
            DEFAULT_SUPERVISOR_VERSION=$(${DOCKER_CMD} "${versioncheck_cmd[@]}")
        fi
        if [ -z "$DEFAULT_SUPERVISOR_VERSION" ]; then
            log ERROR "Could not get the default supervisor version for this resinOS release, bailing out."
        else
            log "Extracted default version is v$DEFAULT_SUPERVISOR_VERSION..."
            target_supervisor_version="$DEFAULT_SUPERVISOR_VERSION"

        fi
    fi

    if CURRENT_SUPERVISOR_VERSION=$(curl -s "${API_ENDPOINT}/v2/device(${DEVICEID})?\$select=supervisor_version&apikey=${APIKEY}" | jq -r '.d[0].supervisor_version'); then
        if [ -z "$CURRENT_SUPERVISOR_VERSION" ]; then
            log ERROR "Could not get current supervisor version from the API..."
        else
            if version_gt "$target_supervisor_version" "$CURRENT_SUPERVISOR_VERSION" ; then
                log "Supervisor update: will be upgrading from v${CURRENT_SUPERVISOR_VERSION} to v${target_supervisor_version}"
                UPDATER_SUPERVISOR_TAG="v${target_supervisor_version}"
                # Get the supervisor id
                if UPDATER_SUPERVISOR_ID=$(curl -s "${API_ENDPOINT}/v2/supervisor_release?\$select=id,image_name&\$filter=((device_type%20eq%20'$SLUG')%20and%20(supervisor_version%20eq%20'$UPDATER_SUPERVISOR_TAG'))&apikey=${APIKEY}" | jq -e -r '.d[0].id'); then
                    log "Extracted supervisor vars: ID: $UPDATER_SUPERVISOR_ID"
                    log "Setting supervisor version in the API..."
                    curl -s "${API_ENDPOINT}/v2/device($DEVICEID)?apikey=$APIKEY" -X PATCH -H 'Content-Type: application/json;charset=UTF-8' --data-binary "{\"supervisor_release\": \"$UPDATER_SUPERVISOR_ID\"}" > /dev/null 2>&1
                    log "Running supervisor updater..."
                    progress 90 "Running supervisor update"
                    update-resin-supervisor
                    stop_services
                    if version_gt "6.5.9" "${target_supervisor_version}" ; then
                        remove_containers
                        log "Removing supervisor database for migration"
                        rm /resin-data/resin-supervisor/database.sqlite || true
                    fi
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

function error_handler() {
    # If script fails (e.g. docker pull fails), restart the stopped services like the supervisor
    systemctl start resin-supervisor
    systemctl start update-resin-supervisor.timer
    exit 1
}

function image_exsits() {
    # Try to fetch the manifest of a repo:tag combo, to check for the existence of that
    # repo and tag.
    # Currently only works with v2 registries
    # The return value is "no" if can't access that manifest, and "yes" if we can find it
    local REGISTRY=$1
    local REPO=$2
    local TAG=$3
    local exists=no
    local REGISTRY_URL="https://${REGISTRY}/v2"
    local MANIFEST="${REGISTRY_URL}/${REPO}/manifests/${TAG}"
    local response

    # Check
    response=$(curl --write-out "%{http_code}" --silent --output /dev/null "${MANIFEST}")
    if [ "$response" = 401 ]; then
        # 401 is "Unauthorized", have to grab the access tokens from the provided endpoint
        local auth_header
        local realm
        local service
        local scope
        local token
        local response_auth
        auth_header=$(curl -I --silent "${MANIFEST}" |grep -i www-authenticate)
        # The auth_header looks as
        # Www-Authenticate: Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:resin/resinos:pull"
        # shellcheck disable=SC2001
        realm=$(echo "$auth_header" | sed 's/.*realm="\([^,]*\)",.*/\1/' )
        # shellcheck disable=SC2001
        service=$(echo "$auth_header" | sed 's/.*,service="\([^,]*\)",.*/\1/' )
        # shellcheck disable=SC2001
        scope=$(echo "$auth_header" | sed 's/.*,scope="\([^,]*\)".*/\1/' )
        # Grab the token from the appropriate address, and retry the manifest query with that
        token=$(curl --silent "${realm}?service=${service}&scope=${scope}" | jq -r '.access_token // .token')
        response_auth=$(curl --write-out "%{http_code}" --silent --output /dev/null -H "Authorization: Bearer ${token}" "${MANIFEST}")
        if [ "$response_auth" = 200 ]; then
            exists=yes
        fi
    elif [ "$response" = 200 ]; then
        exists=yes
    fi
    echo "${exists}"
}

function remove_sample_wifi {
    # Removing the `resin-sample` file if it exists on the device, and has the default
    # connection settings, as they are well known and thus insecure
    local filename=$1
    if [ -f "${filename}" ] && grep -Fxq "ssid=My_Wifi_Ssid" "${filename}" && grep -Fxq "psk=super_secret_wifi_password" "${filename}" ; then
        if nmcli c  show --active | grep "resin-sample" ; then
            # If a connection with that name is in use, do not actually remove the settings
            log WARN "resin-sample configuration found at ${filename} but it might be connected, not removing..."
        else
            log "resin-sample configuration found at ${filename}, removing..."
            rm "${filename}" || log WARN "couldn't remove ${filename}; continuing anyways..."
        fi
    else
        log "No resin-sample found at ${filename} with default config, good..."
    fi
}

function device_type_match {
    # slug in `device-type.json` and `deviceType` in `config.json` should be always the same on proper devices`
    local deviceslug
    local devicetype
    local match
    if deviceslug=$(jq .slug "$DEVICETYPEJSON") && devicetype=$(jq .deviceType "$CONFIGJSON") && [ "$devicetype" = "$deviceslug" ]; then
        match=yes
    else
        match=no
    fi
    echo "${match}"
}

# Pre update cleanup: remove some not-required files from the boot partition to clear some space
function pre_update_pi_bootfiles_removal {
    local boot_files_for_removal=('start_db.elf' 'fixup_db.dat')
    for f in "${boot_files_for_removal[@]}"; do
        echo "Removing $f from boot partition"
        rm -f "/mnt/boot/$f"
    done
    sync /mnt/boot
}

function pre_update_fix_bootfiles_hook {
    log "Applying bootfiles hostapp-hook fix"
    local bootfiles_temp
    bootfiles_temp=$(mktemp)
    curl -f -s -L -o "$bootfiles_temp" https://raw.githubusercontent.com/resin-os/resinhup/77401f3ecdeddaac843b26827f0a44d3b044efdd/upgrade-patches/0-bootfiles || log ERROR "Couldn't download fixed '0-bootfiles', aborting."
    chmod 755 "$bootfiles_temp"
    mount --bind "$bootfiles_temp"  /etc/hostapp-update-hooks.d/0-bootfiles
}

#######################################
# Prepares and runs update based on hostapp-update
# Includes pre-update fixes and balena migration
# Globals:
#   DOCKER_CMD
#   target_version
#   minimum_balena_target_version
# Arguments:
#   update_package: the docker image to use for the update
#   tmp_inactive: host path to the directory that will be bind-mounted to /mnt/sysroot/inactive inside the container
# Returns:
#   None
#######################################
function in_container_hostapp_update {
    local update_package=$1
    local tmp_inactive=$2
    local inactive="/mnt/sysroot/inactive"
    local hostapp_update_extra_args=""
    local target_docker_cmd
    local target_dockerd
    local volumes_args=()

    stop_services
    if [ "${STOP_ALL}" == "yes" ]; then
        remove_containers
    fi

    # Disable rollbacks when doing migration to rollback enabled system, as couldn't roll back anyways
    if version_gt "${target_version}" "2.9.3"; then
        hostapp_update_extra_args="-x"
    fi
    # Set the name of the docker/balena command within the target image to the appropriate one
    if version_gt "${target_version}" "${minimum_balena_target_version}"; then
        target_docker_cmd="balena"
        target_dockerd="balenad"
    else
        target_docker_cmd="docker"
        target_dockerd="dockerd"
    fi

    ${DOCKER_CMD} pull "${update_package}" || log ERROR "Couldn't pull docker image..."
    mkfifo /tmp/resinos-image.docker
    ${DOCKER_CMD} save "${update_package}" > /tmp/resinos-image.docker &
    mkdir -p /mnt/data/resinhup/tmp

    # The setting up the required volumes
    volumes_args+=("-v" "/dev/disk:/dev/disk")
    volumes_args+=("-v" "/mnt/boot:/mnt/boot")
    volumes_args+=("-v" "/mnt/data/resinhup/tmp:/mnt/data/resinhup/tmp")
    if mountpoint "/mnt/sysroot/active"; then
        volumes_args+=("-v" "/mnt/sysroot/active:/mnt/sysroot/active")
    else
        volumes_args+=("-v" "/:/mnt/sysroot/active")
    fi
    volumes_args+=("-v" "${tmp_inactive}:${inactive}")
    volumes_args+=("-v" "/tmp/resinos-image.docker:/resinos-image.docker")

    log "Starting hostapp-update within a container"
    # Note that the following docker daemon is started with a different --bip and --fixed-cidr
    # setting, otherwise it is clashing with the system docker on resinOS >=2.3.0 || <2.5.1
    # and then docker pull would not succeed
    # shellcheck disable=SC2016
    ${DOCKER_CMD} run \
      --rm \
      --name resinhup \
      --privileged \
      "${volumes_args[@]}" \
      "${update_package}" \
      /bin/bash -c 'storage_driver=$(cat /boot/storage-driver) ; DOCKER_TMPDIR=/mnt/data/resinhup/tmp/ '"${target_dockerd}"' --storage-driver=$storage_driver --data-root='"${inactive}"'/'"${target_docker_cmd}"' --host=unix:///var/run/'"${target_docker_cmd}"'-host.sock --pidfile=/var/run/'"${target_docker_cmd}"'-host.pid --exec-root=/var/run/'"${target_docker_cmd}"'-host --bip=10.114.201.1/24 --fixed-cidr=10.114.201.128/25 --iptables=false & timeout_seconds=$((SECONDS+30)); until DOCKER_HOST="unix:///var/run/'"${target_docker_cmd}"'-host.sock" '"${target_docker_cmd}"' ps &> /dev/null; do sleep 0.2; if [ $SECONDS -gt $timeout_seconds ]; then echo "'"${target_docker_cmd}"'-host did not come up before check timed out..."; exit 1; fi; done; echo "Starting hostapp-update"; hostapp-update -f /resinos-image.docker '"${hostapp_update_extra_args}"'' \
    || log ERROR "Update based on hostapp-update has failed..."
}

#######################################
# Prepares and runs update based on hostapp-update
# Includes pre-update fixes and balena migration
# Globals:
#   DOCKER_CMD
#   DOCKERD
#   LEGACY_UPDATE
#   SLUG
#   VERSION_ID
#   target_version
#   minimum_balena_target_version
# Arguments:
#   update_package: the docker image to use for the update
# Returns:
#   None
#######################################
function hostapp_based_update {
    local update_package=$1
    local storage_driver
    local inactive="/mnt/sysroot/inactive"
    local balena_migration=no

    case ${SLUG} in
        raspberry*)
            log "Running pre-update fixes for ${SLUG}"
            pre_update_pi_bootfiles_removal
            if ! version_gt "${VERSION_ID}" "2.7.6" ; then
                pre_update_fix_bootfiles_hook
            fi
            ;;
        *)
            log "No device-specific pre-update fix for ${SLUG}"
    esac


    if [ "${DOCKER_CMD}" = "docker" ] &&
        version_gt "${target_version}" "${minimum_balena_target_version}" ; then
            balena_migration="yes"
    fi

    if ! [ -S "/var/run/${DOCKER_CMD}-host.sock" ]; then
        ## Happens on devices booting after a regular HUP update onto a hostapps enabled resinOS
        log "Do not have ${DOCKER_CMD}-host running; legacy mode"
        LEGACY_UPDATE=yes
        log "Clean inactive partition"
        rm -rf "${inactive:?}/"*
        if [ "$balena_migration" = "no" ]; then
            local storage_driver
            storage_driver=$(cat /boot/storage-driver)
            log "Starting ${DOCKER_CMD}-host with ${storage_driver} storage driver"
            ${DOCKERD} --log-driver=journald --storage-driver="${storage_driver}" --data-root="${inactive}/${DOCKER_CMD}" --host="unix:///var/run/${DOCKER_CMD}-host.sock" --pidfile="/var/run/${DOCKER_CMD}-host.pid" --exec-root="/var/run/${DOCKER_CMD}-host" --bip=10.114.101.1/24 --fixed-cidr=10.114.101.128/25 --iptables=false &
            local timeout_seconds=$((SECONDS+30));
            until DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} ps &> /dev/null; do sleep 0.2; if [ $SECONDS -gt $timeout_seconds ]; then log ERROR "${DOCKER_CMD}-host did not come up before check timed out..."; fi; done
        fi
    else
        if [ -f "$inactive/resinos.fingerprint" ]; then
            # Happens on a device, which has HUP'd from a non-hostapp resinOS to
            # a hostapp version. The previous "active", partition now inactive,
            # and still has leftover data
            log "Have ${DOCKER_CMD}-host running, with dirty inactive partition"
            systemctl stop "${DOCKER_CMD}-host"
            log "Clean inactive partition"
            rm -rf "${inactive:?}/"*
            systemctl start "${DOCKER_CMD}-host"
            local timeout_seconds=$((SECONDS+30));
            until DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} ps &> /dev/null; do sleep 0.2; if [ $SECONDS -gt $timeout_seconds ]; then log ERROR "${DOCKER_CMD}-host did not come up before check timed out..."; fi; done
        fi
        if [ "${DOCKER_CMD}" = "balena" ] &&
            [ -d "$inactive/docker" ]; then
                log "Removing leftover docker folder on a balena device"
                rm -rf "$inactive/docker"
        fi
    fi

    if [ "$balena_migration" = "yes" ]; then
            # Migrating to balena and hostapp-update hooks run inside the target container
            log "Balena migration"
            systemctl stop docker-host || true
            if [ -d "/mnt/sysroot/inactive/docker" ] &&
                [ ! -d "/mnt/sysroot/inactive/balena" ] ; then
                    log "Need to move docker folder on the inactive partition"
                    mv /mnt/sysroot/inactive/{docker,balena} && ln -s /mnt/sysroot/inactive/{balena,docker}
            fi

            in_container_hostapp_update "${update_package}" "${inactive}"

            if [ "${LEGACY_UPDATE}" != "yes" ]; then
                systemctl start docker-host
            fi
    else
        if [ "$STOP_ALL" = "yes" ]; then
            stop_services
            remove_containers
        fi
        log "Starting hostapp-update"
        hostapp-update -i "${update_package}" || log ERROR "hostapp-update has failed..."-
    fi
}

#######################################
# Upgrade from a non-hostapp (<2.7.0) to a hostapp-enabled resinOS version
# Handles both pre-balena and balena updates
# Globals:
#   SLUG
#   minimum_balena_target_version
#   target_version
# Arguments:
#   update_package: the docker image to use for the update
# Returns:
#   None
#######################################
function non_hostapp_to_hostapp_update {
    local update_package=$1
    local tmp_inactive

    # Mount spare root partition
    find_partitions
    umount "${update_part}" || true
    mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 -i 8192 -L "${update_label}" "${update_part}"
    tmp_inactive=$(mktemp -d)
    mount "${update_part}" "${tmp_inactive}" || log ERROR "Cannot mount inactive partition ${update_part} to ${tmp_inactive}..."

    case "${SLUG}" in
        raspberry*)
            log "Running pre-update fixes for ${SLUG}"
            pre_update_pi_bootfiles_removal
            ;;
        *)
            log "No device-specific pre-update fix for ${SLUG}"
    esac

    in_container_hostapp_update "${update_package}" "${tmp_inactive}"
}

function find_partitions {
    # Find which partition is / and which we should write the update to
    # This function is only used in pre-hostapp-update-enabled 2.x devices
    root_part=$(findmnt -n --raw --evaluate --output=source /)
    log "Found root at ${root_part}..."
    case ${root_part} in
        # on 2.x the following device types have these kinds of results for $root_part, examples
        # raspberrypi: /dev/mmcblk0p2
        # beaglebone: /dev/disk/by-partuuid/93956da0-02
        # edison: /dev/disk/by-partuuid/012b3303-34ac-284d-99b4-34e03a2335f4
        # NUC: /dev/disk/by-label/resin-rootA and underlying /dev/sda2
        # up-board: /dev/disk/by-label/resin-rootA and underlying /dev/mmcblk0p2
        /dev/disk/by-partuuid/*)
            # reread the physical device that that part refers to
            root_part=$(readlink -f "${root_part}")
            case ${root_part} in
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
                *p8)
                    root_dev=${root_part%p8}
                    update_part=${root_dev}p9
                    update_part_no=9
                    update_label=resin-rootB
                    ;;
                *p9)
                    root_dev=${root_part%p9}
                    update_part=${root_dev}p8
                    update_part_no=8
                    update_label=resin-rootA
                    ;;
                *)
                    log ERROR "Couldn't get the root partition from the part-uuid..."
            esac
            ;;
        /dev/disk/by-label/resin-rootA)
            old_label=resin-rootA
            update_label=resin-rootB
            root_part_dev=$(readlink -f /dev/disk/by-label/${old_label})
            update_part=${root_part_dev%2}3
            ;;
        /dev/disk/by-label/resin-rootB)
            old_label=resin-rootB
            update_label=resin-rootA
            root_part_dev=$(readlink -f /dev/disk/by-label/${old_label})
            update_part=${root_part_dev%3}2
            ;;
        *2)
            root_dev=${root_part%2}
            update_part=${root_dev}3
            update_part_no=3
            update_label=resin-rootB
            ;;
        *3)
            root_dev=${root_part%3}
            update_part=${root_dev}2
            update_part_no=2
            update_label=resin-rootA
            ;;
        *)
            log ERROR "Unknown root partition ${root_part}."
    esac
    if [ ! -b "${update_part}" ]; then
        log ERROR "Update partition detected as ${update_part} but it's not a block device."
    fi
    log "Update partition: ${update_part}"
}

function finish_up() {
    sync
    if [ "${NOREBOOT}" == "no" ]; then
        # Reboot into new OS
        log "Rebooting into new OS in 5 seconds..."
        progress 100 "Update successful, rebooting"
        nohup bash -c "sleep 5 ; reboot " > /dev/null 2>&1 &
    else
        log "Finished update, not rebooting as requested."
        progress 100 "Update successful"
    fi
    exit 0
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
        --force-slug)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            SLUG=$2
            shift
            ;;
        --hostos-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            target_version=$2
            case $target_version in
                *.prod)
                    target_version="${target_version%%.prod}"
                    log "Normalized target version: ${target_version}"
                    ;;
                *.dev)
                    log ERROR "Updating .dev versions is not supported..."
                    ;;
            esac
            shift
            ;;
        --resinos-registry)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            RESINOS_REGISTRY=$2
            shift
            ;;
        --resinos-repo)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            RESINOS_REPO=$2
            shift
            ;;
        --resinos-tag)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            RESINOS_TAG=$2
            shift
            ;;
        --supervisor-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            target_supervisor_version=$2
            shift
            ;;
        -n|--nolog)
            LOG=no
            ;;
        --no-reboot)
            NOREBOOT="yes"
            ;;
        --ignore-sanity-checks)
            IGNORE_SANITY_CHECKS="yes"
            ;;
        --staging)
            log WARN "The --staging flag is deprecated for this script, use --resinos-repo <REPOSITORY>"
            log WARN "For backwards compatibility, this flag acts the same as --resinos-repo resin/resinos-staging, and overrides that flag if set"
            RESINOS_REPO_STAGING="resin/resinos-staging"
            ;;
        --stop-all)
            STOP_ALL="yes"
            ;;
        *)
            log WARN "Unrecognized option $1."
            ;;
    esac
    shift
done

# Run on start
_prepare_locking
# Try to get lock, and exit if cannot, meaning another instance is running already
exlock_now || exit 9

if [ -n "$RESINOS_REPO_STAGING" ]; then
    RESINOS_REPO="${RESINOS_REPO_STAGING}"
fi

if [ -z "$target_version" ]; then
    log ERROR "--hostos-version is required."
fi

# Log timer
starttime=$(date +%s)

# LOGFILE init and header
if [ "$LOG" == "yes" ]; then
    LOGFILE="/mnt/data/resinhup/$SCRIPTNAME.$(date +"%Y%m%d_%H%M%S").log"
    mkdir -p "$(dirname "$LOGFILE")"
    echo "================$SCRIPTNAME HEADER START====================" > "$LOGFILE"
    date >> "$LOGFILE"
    # redirect all logs to the logfile
    exec 1> "$LOGFILE" 2>&1
fi

progress 25 "Preparing OS update"

# Check board support
case $SLUG in
    artik710)
        binary_type=arm
        ;;
    beaglebone*)
        binary_type=arm
        ;;
    raspberry*)
        binary_type=arm
        ;;
    jetson-tx2|skx2)
        binary_type=arm
        ;;
    ts4900)
        binary_type=arm
        ;;
    intel-edison|intel-nuc|iot2000|up-board|qemux86*)
        binary_type=x86
        ;;
    *)
        log ERROR "Unsupported board type $SLUG."
esac

log "Loading info from config.json"
if [ -f /mnt/boot/config.json ]; then
    CONFIGJSON=/mnt/boot/config.json
else
    log ERROR "Don't know where config.json is."
fi
log "Loading info from device-type.json"
if [ -f /mnt/boot/device-type.json ]; then
    DEVICETYPEJSON=/mnt/boot/device-type.json
elif [ -f /resin-boot/device-type.json ]; then
    DEVICETYPEJSON=/resin-boot/device-type.json
else
    log ERROR "Don't know where device-type.json is."
fi
# If the user api key exists we use it instead of the deviceApiKey as it means we haven't done the key exchange yet
APIKEY=$(jq -r '.apiKey // .deviceApiKey' $CONFIGJSON)
DEVICEID=$(jq -r '.deviceId' $CONFIGJSON)
API_ENDPOINT=$(jq -r '.apiEndpoint' $CONFIGJSON)

## Sanity checks
device_type_check=$(device_type_match)
if [ "$device_type_check" = "yes" ]; then
    log "Device type check: OK"
else
    if [ "$IGNORE_SANITY_CHECKS" = "yes" ]; then
        log WARN "Device type sanity check failed, but asked to ignore..."
    else
        log ERROR "Device type sanity check failed..."
    fi
fi
## Sanity checks end

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
log "VARIANT_ID: ${VARIANT_ID}"
if [ -n "$VARIANT_ID" ] && [ ! "$VARIANT_ID" == "prod" ]; then
    log ERROR "Only updating production devices..."
fi

# Check host OS version
case $VERSION in
    2.*)
        log "Host OS version \"$VERSION\" OK."
        ;;
    *)
        log ERROR "Host OS version \"$VERSION\" not supported."
        ;;
esac

# Translate version to one docker will accept as part of an image name
target_version=$(echo "$target_version" | tr + _)

# Checking whether the target version is available to download
if [ -z "$RESINOS_TAG" ]; then
    RESINOS_TAG=${target_version}-${SLUG}
fi
image="${RESINOS_REGISTRY}/${RESINOS_REPO}:${RESINOS_TAG}"
log "Checking for manifest of ${image}"
if [ "$(image_exsits "$RESINOS_REGISTRY" "$RESINOS_REPO" "$RESINOS_TAG")" = "yes" ]; then
    log "Manifest found, good to go..."
else
    log ERROR "Cannot find manifest, target image might not exists. Bailing out..."
fi

# Check if we need to install some more extra tools
if ! version_gt "$VERSION" "$preferred_hostos_version" &&
    ! [ "$VERSION" == "$preferred_hostos_version" ]; then
    log "Host OS version $VERSION is less than $preferred_hostos_version, installing tools..."
    tools_path=/tmp/upgrade_tools
    tools_binaries="tar"
    mkdir -p $tools_path
    export PATH=$tools_path:$PATH
    case $binary_type in
        arm|x86)
            download_uri=https://github.com/resin-os/resinhup/raw/master/upgrade-binaries/$binary_type
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

# fix resin-device-progress, between version 2.0.6 and 2.3.0
# the script does not work using deviceApiKey
if version_gt "$VERSION_ID" "2.0.6" &&
    version_gt "2.3.0" "$VERSION_ID"; then
        log "Fixing resin-device-progress is required..."
        tools_path=/tmp/upgrade_tools_extra
        mkdir -p $tools_path
        export PATH=$tools_path:$PATH
        download_url=https://raw.githubusercontent.com/resin-os/meta-resin/v2.3.0/meta-resin-common/recipes-support/resin-device-progress/resin-device-progress/resin-device-progress
        curl -f -s -L -o $tools_path/resin-device-progress $download_url || log WARN "Couldn't download tool from $download_url, progress bar won't work, but not aborting..."
        chmod 755 $tools_path/resin-device-progress
else
    log "No resin-device-progress fix is required..."
fi

# Fix for issue: https://github.com/resin-os/meta-resin/pull/864
# Also includes change from: https://github.com/resin-os/meta-resin/pull/882
if version_gt "$VERSION_ID" "2.0.8" &&
    version_gt "2.7.0" "$VERSION_ID"; then
        log "Fixing supervisor updater..."
        if curl --fail --silent -o "/tmp/update-resin-supervisor" https://raw.githubusercontent.com/resin-os/meta-resin/40d5a174da6b52d530c978e0cae22aa61f65d203/meta-resin-common/recipes-containers/docker-disk/docker-resin-supervisor-disk/update-resin-supervisor ; then
            chmod 755 "/tmp/update-resin-supervisor"
            PATH="/tmp:$PATH"
            log "Added temporary supervisor updater replaced with fixed version..."
        else
            log ERROR "Could not download temporary supervisor updater..."
        fi
else
    log "No supervisor updater fix is required..."
fi

# Fix issue with `read` on 2.10.x/2.11.0 resinOS versions
if version_gt "$VERSION_ID" "2.9.7" &&
    version_gt "2.11.1" "$VERSION_ID"; then
        log "Fixing supervisor updater if needed..."
        #shellcheck disable=SC2016
        sed 's/read tag image_name <<<$data/read tag <<<"$(echo "$data" | head -n 1)" ; read image_name <<<"$(echo "$data" | tail -n 1)"/' /usr/bin/update-resin-supervisor > /tmp/fixed-update-resin-supervisor && \
          chmod +x /tmp/fixed-update-resin-supervisor && \
          mount -o bind /tmp/fixed-update-resin-supervisor /usr/bin/update-resin-supervisor
fi

# The timesyncd.conf lives on the state partition starting from resinOS 2.1.0
# For devices that were updated before this fix came to effect, fix things up, otherwise migrate when updating
if [ -d "/mnt/state/root-overlay/etc/systemd/timesyncd.conf" ]; then
    rm -rf "/mnt/state/root-overlay/etc/systemd/timesyncd.conf"
    cp "/etc/systemd/timesyncd.conf" "/mnt/state/root-overlay/etc/systemd/timesyncd.conf"
    systemctl restart etc-systemd-timesyncd.conf.mount
    log "timesyncd.conf mount service fixed up"
elif ! [ -f "/mnt/state/root-overlay/etc/systemd/timesyncd.conf" ] && version_gt "$target_version" "2.1.0"; then
    cp "/etc/systemd/timesyncd.conf" "/mnt/state/root-overlay/etc/systemd/timesyncd.conf"
    log "timesyncd.conf migrated to the state partition"
fi

### hostapp-update based updater

if version_gt "${VERSION_ID}" "${minimum_hostapp_target_version}" ||
    [ "${VERSION_ID}" == "${minimum_hostapp_target_version}" ]; then
    log "hostapp-update command exists, use that for update"
    progress 50 "Running OS update"
    hostapp_based_update "${image}"

    if [ "${LEGACY_UPDATE}" = "yes" ]; then
        upgrade_supervisor "${image}" no_docker_host
    else
        upgrade_supervisor "${image}"
    fi

    finish_up

elif version_gt "${target_version}" "${minimum_hostapp_target_version}" ||
     [ "${target_version}" == "${minimum_hostapp_target_version}" ]; then
    log "Running update from a non-hostapp-update enabled version to a hostapp-update enabled version..."
    progress 50 "Running OS update"
    non_hostapp_to_hostapp_update "${image}"

    upgrade_supervisor "${image}" no_docker_host

    finish_up
fi

### Below here is the regular, non-hostapp resinOS host update

# Find partition information
find_partitions

# Stop supervisor, plus all running containers if requested
stop_services
if [ "${STOP_ALL}" = "yes" ]; then
    remove_containers
fi

trap 'error_handler' ERR

log "Getting new OS image..."
progress 50 "Downloading OS update"
# Create container for new version
container=$(${DOCKER_CMD} create "$image" echo export)

progress 75 "Running OS update"

log "Making new OS filesystem..."
# Format alternate root partition
log "Update partition: ${update_part}"
mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 -i 8192 -L "$update_label" "$update_part"

# Mount alternate root partition
mkdir -p /tmp/updateroot
mount "$update_part" /tmp/updateroot

# Extract rootfs
log "Extracting new rootfs..."
cat >/tmp/root-exclude <<EOF
quirks
resin-boot
EOF
${DOCKER_CMD} export "$container" | tar -x -X /tmp/root-exclude -C /tmp/updateroot

# Extract quirks
${DOCKER_CMD} export "$container" | tar -x -C /tmp quirks
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
${DOCKER_CMD} export "$container" | tar -x -X /tmp/boot-exclude -C /tmp resin-boot
cp -a /tmp/resin-boot/* /mnt/boot/

# Clearing up
${DOCKER_CMD} rm "$container"

# Updating supervisor
upgrade_supervisor "$image" no_docker_host

# REmove resin-sample to plug security hole
remove_sample_wifi "/mnt/boot/system-connections/resin-sample"
remove_sample_wifi "/mnt/state/root-overlay/etc/NetworkManager/system-connections/resin-sample"

# Switch root partition
log "Switching root partition..."
case $SLUG in
    artik710|beaglebone*)
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

finish_up
