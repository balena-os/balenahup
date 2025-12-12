#!/bin/bash

# default configuration
NOREBOOT=no
DELTA_VERSION=3
SCRIPTNAME=upgrade-2.x.sh
STOP_ALL=no

set -o errexit
set -E
set -o pipefail

minimum_hostos_version=2.14.0
minimum_target_version=2.16.0
minimum_supervisor_stop=2.53.10

# This will set VERSION, SLUG
# shellcheck disable=SC1091
. /etc/os-release

# Don't run anything before this source as it sets PATH here
# shellcheck disable=SC1091
source /etc/profile

DOCKER_CMD="balena"

###
# Helper functions
###

# Preventing running multiple instances of upgrades running
LOCKFILE="/var/lock/resinhup.lock"
LOCKFD=99
## Private functions
_lock()             { flock "-$1" $LOCKFD; }
_exit_handler() {
    _exit_status=$?
    if [ "${_exit_status}" -ne 0 ]; then
        log "Exit on error ${_exit_status}"
        if ! report_update_failed > /dev/null 2>&1; then
            log "Failed to report progress on exit with status $?"
        fi
        if [ "${_exit_status}" -eq 9 ]; then
           log "No concurrent updates allowed - lock file in place."
        fi
    fi
    _no_more_locking
    log "Lock removed - end."
}
_no_more_locking()  { _lock u; _lock xn && rm -f $LOCKFILE;rm -f "${outfifo}";rm -f "${errfifo}"; }
_prepare_locking()  { eval "exec $LOCKFD>\"$LOCKFILE\""; trap _exit_handler EXIT; }
# Public functions
exlock_now()        { _lock xn; }  # obtain an exclusive lock immediately or fail

# workaround for self-signed certs, waiting for https://github.com/balena-os/meta-balena/issues/1398
TMPCRT=$(mktemp)
jq -r '.balenaRootCA' < /mnt/boot/config.json | base64 -d > "${TMPCRT}"
cat /etc/ssl/certs/ca-certificates.crt >> "${TMPCRT}"

CURL="curl --silent --retry 10 --fail --location --compressed"

# Dashboard progress helper
function progress {
    percentage=$1
    message=$2
    resin-device-progress --percentage "${percentage}" --state "${message}" > /dev/null || true
}

function help {
    cat << EOF
Helper to run hostOS updates on balenaOS 2.x devices

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

  --balenaos-registry
        Upstream registry to use for host OS applications.

  --stop-all
        Request the updater to stop all containers (including user application)
        before the update.
EOF
}

function report_update_failed() {
    perc=100
    state="OS update failed"
    while ! compare_device_state "${perc}" "${state}"; do
        ((c++)) && ((c==60)) && break
        if resin-device-progress --percentage "${perc}" --state "${state}"; then
            continue
        fi
        log WARN "Retrying failure report - try $c"
        sleep 60
    done
}

# Log function helper
function log {
    # Address log levels
    priority=6
    case $1 in
        ERROR)
            loglevel=ERROR
            priority=3
            shift
            ;;
        WARN)
            loglevel=WARNING
            priority=4
            shift
            ;;
        *)
            loglevel=INFO
            ;;
    esac
    echo "${1}" | systemd-cat --level-prefix=0 --identifier="${SCRIPTNAME}" --priority="${priority}" 2> /dev/null || true
    endtime=$(date +%s)
    printf "[%s][%09d%s%s\n" "$SCRIPTNAME" "$((endtime - starttime))" "][$loglevel]" "$1"
    if [ "$loglevel" == "ERROR" ]; then
        exit 1
    fi
}

# Test if a version is greater than another
function version_gt() {
    test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"
}

function compare_device_state() {
    perc=$1
    state=$2
    local resp
    local remote_perc
    local remote_state
    resp=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} --header "Authorization: Bearer ${APIKEY}" \
        "${API_ENDPOINT}/v6/device(uuid='${UUID}')?\$select=provisioning_state,provisioning_progress" | jq '.d[]')
    remote_perc=$(echo "${resp}" | jq -r '.provisioning_progress')
    remote_state=$(echo "${resp}" | jq -r '.provisioning_state')
    if [ -n "${remote_perc}" ] && [ -n "${remote_state}" ]; then
        test "${perc}" -eq "${remote_perc}" && test "${state}" = "${remote_state}"
    else
        return 1
    fi
}

function stop_services() {
    # Stopping supervisor and related services
    log "Stopping supervisor and related services..."
    systemctl stop update-balena-supervisor.timer > /dev/null 2>&1 || systemctl stop update-resin-supervisor.timer > /dev/null 2>&1
    systemctl stop balena-supervisor  > /dev/null 2>&1 || systemctl stop resin-supervisor > /dev/null 2>&1
    ${DOCKER_CMD} rm -f balena_supervisor resin_supervisor > /dev/null 2>&1 || true
}

function remove_containers() {
    log "Stopping all containers.."
    # shellcheck disable=SC2046
    ${DOCKER_CMD} stop $(${DOCKER_CMD} ps -a -q) > /dev/null 2>&1 || true
    log "Removing all containers..."
    # shellcheck disable=SC2046
    ${DOCKER_CMD} rm $(${DOCKER_CMD} ps -a -q) > /dev/null 2>&1 || true
}

function remove_rec_files() {
    local boot_dir='/mnt/boot'
    shopt -s nullglob
    for f in "${boot_dir}"/*.REC; do
        log WARN "Removing $f from boot partition"
        rm -f "$f"
    done
    sync ${boot_dir}
}

#######################################
# Helper function to run a transient unit to update the supervisor.
# Returns
#   0: Success
#   1: Failure
#######################################
function _run_supervisor_update() {
    local supervisor_update
    local ret=0
    local update_balena_supervisor_script

    update_balena_supervisor_script="$(command -v update-balena-supervisor || command -v update-resin-supervisor)"
    # use a transient unit in order to namespace-collide with a potential API-initiated update
    if grep -q "os-helpers-logging" "${update_balena_supervisor_script}"; then
        #  if the update-balena-supervisor script used os-helpers-logging append stderr to the log file
        supervisor_update="systemd-run --wait --property=StandardError=append:${LOGFILE} --unit run-update-supervisor ${update_balena_supervisor_script}"
    else
        supervisor_update="systemd-run --wait --unit run-update-supervisor ${update_balena_supervisor_script}"
    fi
    if version_gt "${HOST_OS_VERSION}" "${minimum_supervisor_stop}"; then
        supervisor_update+=' -n'
    fi
    if ! eval "${supervisor_update}"; then
        log WARN "Supervisor couldn't be updated" && ret=1
    fi
    journalctl -a -u run-update-supervisor --no-pager || true
    return "${ret}"
}

# Fetch the current and scheduled supervisor versions from the API
#
# Returns:
#
#  0: Success
#  1: Failure
#
#  Outputs:
#
#  On success, a string separated string of current and scheduled supervisor
#  versions.
#
function _fetch_supervisor_version() {
    local resp
    local supervisor_version
    local scheduled_supervisor_version

      resp=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} --header "Authorization: Bearer ${APIKEY}" "${API_ENDPOINT}/v6/device(uuid='${UUID}')?\$select=supervisor_version&\$expand=should_be_managed_by__supervisor_release(\$top=1;\$select=supervisor_version)")
    if supervisor_version=$(echo "${resp}" | jq -e -r '.d[0].supervisor_version' | tr -d 'v'); then
        if [ -z "${supervisor_version}" ]; then
            log ERROR "Could not get current supervisor version from the API, got ${resp}"
            return 1
        fi
        scheduled_supervisor_version=$(echo "${resp}" | jq -e -r '.d[0].should_be_managed_by__supervisor_release[0].supervisor_version' | tr -d 'v')
        if [ -n "${scheduled_supervisor_version}" ] && [ "${scheduled_supervisor_version}" != "null" ]; then
            if version_gt "${scheduled_supervisor_version}" "${supervisor_version}"; then
		# The supervisor is scheduled to update
                echo "${supervisor_version} ${scheduled_supervisor_version}"
                return 0
            fi
        fi
        echo "${supervisor_version} ${supervisor_version}"
    else
        log ERROR "Could not fetch current supervisor version from the API, got ${resp}"
        return 1
    fi
}

#######################################
# Helper function to patch the supervisor version in the target state.
# Globals:
#   API_ENDPOINT
#   APIKEY
#   UUID
#   SLUG
# Arguments:
#   version: supervisor version to update the target state to
# Returns
#   0: Success
#   1: Failure
#######################################
function _patch_supervisor_version() {
    local version=$1
    local current_version
    local _status_code
    local _errfile
    local _outfile
    local UPDATER_SUPERVISOR_TAG
    local UPDATER_SUPERVISOR_ID

    [ -z "${version}" ] && log "Supervisor version is required" && return 1
    UPDATER_SUPERVISOR_TAG="v${version}"

    # Get the supervisor id
    resp=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} --header "Authorization: Bearer ${APIKEY}" "${API_ENDPOINT}/v5/supervisor_release?\$select=id,image_name&\$filter=((device_type%20eq%20'$SLUG')%20and%20(supervisor_version%20eq%20'${UPDATER_SUPERVISOR_TAG}'))")
    if UPDATER_SUPERVISOR_ID=$(echo "${resp}" | jq -e -r '.d[0].id'); then
        log "Extracted supervisor vars: ID: $UPDATER_SUPERVISOR_ID"
        log "Setting supervisor version in the API..."

        _errfile=$(mktemp)
        _outfile=$(mktemp)
        if _status_code=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} --request PATCH -w "%{http_code}" --show-error -o "${_outfile}" --header "Authorization: Bearer ${APIKEY}" --header 'Content-Type: application/json' "${API_ENDPOINT}/v6/device(uuid='${UUID}')" --data-binary "{\"should_be_managed_by__supervisor_release\": \"${UPDATER_SUPERVISOR_ID}\"}" 2> "${_errfile}"); then
            rm -f "${_errfile}"
            case "${_status_code}" in
                2*) log "Successfully set supervision version in target state";rm -f "${_outfile}";return 0;;
                4*) log WARN "[${_status_code}]: Bad request: $(cat "${_outfile}")"; rm -f "${_outfile}"; if current_version=$(_fetch_supervisor_version | cut -d " " -f1); then if version_gt "${current_version}" "${version}"; then return 0; else return 1; fi; else return 1; fi;;
                *) log WARN "[${_status_code}]: Request failed: $(cat "${_outfile}")";rm -f "${_outfile}";return 1;;
            esac
        else
            log WARN "$(cat "${_errfile}")"
            rm -f "${_errfile}"
            return 1
        fi
    else
        log WARN "Failed fetching supervisor id from API: ${resp}"
        return 1
    fi
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
#   UUID
#   SLUG
#   target_supervisor_version
# Arguments:
#   image: the docker image to exctract the config from
# Returns:
#   None
#######################################
function upgrade_supervisor() {
    local image=$1
    log "Supervisor update start..."

    if [ -z "$target_supervisor_version" ]; then
        log "No explicit supervisor version was provided, update to default version in target balenaOS..."
        local DEFAULT_SUPERVISOR_VERSION
        versioncheck_cmd=("run" "--rm" "${image}" "bash" "-c" "cat /etc/*-supervisor/supervisor.conf | sed -rn 's/SUPERVISOR_(TAG|VERSION)=v(.*)/\\2/p'")
        DEFAULT_SUPERVISOR_VERSION=$(DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} "${versioncheck_cmd[@]}")
        if [ -z "$DEFAULT_SUPERVISOR_VERSION" ]; then
            log ERROR "Could not get the default supervisor version for this balenaOS release, bailing out."
        else
            log "Extracted default version is v$DEFAULT_SUPERVISOR_VERSION..."
            target_supervisor_version="$DEFAULT_SUPERVISOR_VERSION"

        fi
    fi

    if supervisor_target_state_versions=$(_fetch_supervisor_version); then
        read -r CURRENT_SUPERVISOR_VERSION SCHEDULED_SUPERVISOR_VERSION <<< "${supervisor_target_state_versions}"
        log "Supervisor state: Target ${target_supervisor_version}, current ${CURRENT_SUPERVISOR_VERSION}, scheduled ${SCHEDULED_SUPERVISOR_VERSION}"

        # If scheduled higher than current and target, update to scheduled
        # If scheduled not higher than current:
        #  If target higher than current, patch and update to target
        #  If target not higher than current, do nothing

        if ! version_gt "${SCHEDULED_SUPERVISOR_VERSION}" "${CURRENT_SUPERVISOR_VERSION}"; then
            # Supervisor target state current version is higher or equal than the scheduled version.
            if version_gt "$target_supervisor_version" "$CURRENT_SUPERVISOR_VERSION" ; then
                # Supervisor target version is higher than current target state version
                log "Patching supervisor target state from v${CURRENT_SUPERVISOR_VERSION} to v${target_supervisor_version}"
                progress 90 "Patching supervisor update"
                if ! _patch_supervisor_version "$target_supervisor_version"; then
                    log ERROR "Failed to patch supervisor version in target state, bailing out."
                fi
            else
                log "Supervisor update: no update needed."
                return 0
            fi
        else
            # Supervisor target state scheduled version is higher than the current version
            if version_gt "$SCHEDULED_SUPERVISOR_VERSION" "$target_supervisor_version" ; then
                target_supervisor_version="$SCHEDULED_SUPERVISOR_VERSION"
            fi
        fi
        log "Updating supervisor target state from v${CURRENT_SUPERVISOR_VERSION} to v${target_supervisor_version}"
        progress 95 "Running supervisor update"
        if _run_supervisor_update; then
            if version_gt "6.5.9" "${target_supervisor_version}" ; then
                remove_containers
                log "Removing supervisor database for migration"
                rm /resin-data/resin-supervisor/database.sqlite || true
            fi
        else
            log WARN "Failed to update supervisor version - leave to next boot."
        fi
    else
        log ERROR "Failed to fetch current supervisor version from the API."
    fi

    # Post supervisor update fixes
    persistent_logging_config_var
}

function error_handler() {
    # If script fails (e.g. docker pull fails), restart the stopped services like the supervisor
    systemctl start balena-supervisor resin-supervisor || true
    systemctl start update-balena-supervisor.timer update-resin-supervisor.timer || true
    exit 1
}

# Pre update cleanup: remove some not-required files from the boot partition to clear some space
function pre_update_pi_bootfiles_removal {
    local boot_files_for_removal=('start_db.elf' 'fixup_db.dat')
    for f in "${boot_files_for_removal[@]}"; do
        log "Removing $f from boot partition"
        rm -f "/mnt/boot/$f"
    done
    sync /mnt/boot
}

function pre_update_jetson_fix {
    log "Caching current extlinux.conf for ${SLUG} fix"
    extlinux_root_path="boot/extlinux"
    mkdir -p "/tmp/${extlinux_root_path}"
    cp "/mnt/${extlinux_root_path}/extlinux.conf" "/tmp/${extlinux_root_path}/extlinux.conf"
    log "Stopping supervisor to prevent reboots during extlinux.conf updating"
    stop_services
}

function parse_isolcpus {
    path=$1
    if grep -q "isolcpus=" "${path}" ; then
        # shellcheck disable=SC2013
        for val in $(awk '/isolcpus=/' "${path}"); do
            if echo "${val}" | grep -q "isolcpus="; then
                echo "${val}"
            fi
        done
    fi
}

function post_update_jetson_fix {
    log "Applying extlinux.conf fix for ${SLUG}"
    # check if current config has isolcpus set in extlinux.conf
    extlinux_file="boot/extlinux/extlinux.conf"
    uEnv_file="/mnt/boot/extra_uEnv.txt"
    new_extlinux="/mnt/${extlinux_file}"
    old_extlinux="/tmp/${extlinux_file}"
    # step 1, translate the values from extlinux.conf
    local OLD_isolcpus NEW_isolcpus replacement_isolcpu
    OLD_isolcpus=$(parse_isolcpus "${old_extlinux}")
    NEW_isolcpus=$(parse_isolcpus "${new_extlinux}")
    if [ "${OLD_isolcpus}" != "${NEW_isolcpus}" ]; then
        replacement_isolcpu=$(mktemp)
        cp "${new_extlinux}" "${replacement_isolcpu}"
        log "extlinux difference detected"
        if [ -n "${NEW_isolcpus}" ]; then
            log "replacing \`isolcpu\` value in extlinux.conf"
            sed -in "s/${NEW_isolcpus}/${OLD_isolcpus}/" "${replacement_isolcpu}"
        else
            log "adding previous \`isolcpu\` value to extlinux.conf"
            sed -in "/APPEND/s/$/ ${OLD_isolcpus}/" "${replacement_isolcpu}"
        fi
        # do replacement
        mv "${replacement_isolcpu}" "${new_extlinux}" && sync "${new_extlinux}"
    fi

    # step 2, port across the FDT directive
    FDT_value=$(awk '/^ *FDT/{print $NF}' ${old_extlinux})
    if [ -n "${FDT_value}" ] && [ "${FDT_value}" != "default" ]; then
        log "adding previous \`FDT\` value in ${uEnv_file}"
        echo "custom_fdt_file=${FDT_value}" >> "${uEnv_file}" && sync "${uEnv_file}"
    fi

    # step 3, port across entire APPEND
    APPEND_value=$(awk '/^ *APPEND/{for (i=2; i<=NF; i++) printf $i " "; print $NF}' ${old_extlinux})
    if [ -n "${APPEND_value}" ]; then
        if [ -e "${uEnv_file}" ] && grep -q extra_os_cmdline "${uEnv_file}"; then
            log "replacing previous \`APPEND\` value in ${uEnv_file}"
            sed -in "s/extra_os_cmdline=.*/extra_os_cmdline=${APPEND_value}/" "${uEnv_file}" && sync "${uEnv_file}"
        else
            log "appending previous \`APPEND\` value in ${uEnv_file}"
            echo "extra_os_cmdline=${APPEND_value}" >> "${uEnv_file}" && sync "${uEnv_file}"
        fi
    fi

    if [ -e "${uEnv_file}" ] && grep -q '^os_bc_lim=' "${uEnv_file}"; then
        log "Fix for jetson-tx2 bootcount limit already applied"
    else
        echo "os_bc_lim=3" >>  "${uEnv_file}" && sync "${uEnv_file}"
        log "Applied fix for jetson-tx2 bootcount limit to extra_uEnv.txt"
    fi
}

#######################################
# Update problematic persistent logging env var
# Earlier supervisors might have set it to "", and
# that doesn't validate on newer supervisor versions.
# Convert into proper false value.
# Globals:
#   API_ENDPOINT
#   APIKEY
#   CONFIGJSON
#   UUID
# Returns:
#   None
#######################################
function persistent_logging_config_var {
    PROBLEMATIC_ENV_VAR=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} "${API_ENDPOINT}/v5/device_config_variable?\$filter=device/uuid%20eq%20'${UUID}'" -H "Content-Type: application/json" -H "Authorization: Bearer ${APIKEY}" | jq -r '.d[] | select((.name == "RESIN_SUPERVISOR_PERSISTENT_LOGGING") and (.value == "")) | .id')
    if [ -n "${PROBLEMATIC_ENV_VAR}" ]; then
        local tmpfile
        log "Updating problematic RESIN_SUPERVISOR_PERSISTENT_LOGGING config variable"
        CURL_CA_BUNDLE="${TMPCRT}" ${CURL} -X PATCH \
            "${API_ENDPOINT}/v5/device_config_variable(${PROBLEMATIC_ENV_VAR})" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${APIKEY}" \
            --data '{
                "value": "false"
            }' >> /dev/null
        log "Updating config.json with sanitized '.persistentLogging' value."
        tmpfile=$(mktemp -t configjson.XXXXXXXX)
        jq '.persistentLogging="false"' < "${CONFIGJSON}" > "${tmpfile}"
        # 2-step move for atomicity
        cp "${tmpfile}" "$CONFIGJSON.temp" || log ERROR "Couldn't copy temporary config.json to final partition."
        sync
        mv "$CONFIGJSON.temp" "$CONFIGJSON" || log ERROR "Couldn't move updated config.json onto original."
        sync
    fi
}

#######################################
# Prepares and runs update based on hostapp-update
# Includes pre-update fixes and balena migration
# Globals:
#   DOCKER_CMD
#   SLUG
#   HOST_OS_VERSION
#   target_version
# Arguments:
#   update_package: the docker image to use for the update
# Returns:
#   None
#######################################
function hostapp_based_update {
    local update_package=$1
    local inactive="/mnt/sysroot/inactive"
    local inactive_used
    local hostapp_image_count
    local active_part_dev
    local inactive_part_dev

    # Resolve the active and inactive partition devices and canonicalize links
    active_part_dev=$(df -P /mnt/sysroot/active | tail -1 | awk '{print $1}' | xargs readlink -f)
    inactive_part_dev=$(df -P /mnt/sysroot/inactive | tail -1 | awk '{print $1}' | xargs readlink -f)

    # Check that the inactive partition is not the same as active.
    # This avoids any issues with partitions being mislabled leading to a bricked device.
    if [[ "${active_part_dev}" = "${inactive_part_dev}" ]]; then
        log ERROR "Active and inactive partitions are the same, bailing out..."
    fi

    # remove REC files on boot partition
    remove_rec_files

    case ${SLUG} in
        raspberry*)
            log "Running pre-update fixes for ${SLUG}"
            pre_update_pi_bootfiles_removal
            ;;
        jetson-tx2)
            log "Running pre-update fixes for ${SLUG}"
            if version_gt "${HOST_OS_VERSION}" "2.31.1" && version_gt "2.84.7" "${target_version}" ; then
                export JETSON_FIX=1
                pre_update_jetson_fix
            fi
            ;;
        *)
            log "No device-specific pre-update fix for ${SLUG}"
    esac


    if [ -f "$inactive/resinos.fingerprint" ]; then
        # Happens on a device, which has HUP'd from a non-hostapp balenaOS to
        # a hostapp version. The previous "active", partition now inactive,
        # and still has leftover data
        log "Have ${DOCKER_CMD}-host running, with dirty inactive partition"
        systemctl stop "${DOCKER_CMD}-host"
        log "Clean inactive partition"
        rm -rf "${inactive:?}/"*
        systemctl start "${DOCKER_CMD}-host"
        local timeout_iterations=0
        until DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} ps &> /dev/null; do sleep 0.2; if [ $((timeout_iterations++)) -ge 1500 ]; then log ERROR "${DOCKER_CMD}-host did not come up before check timed out..."; fi; done
    fi
    if [ "${DOCKER_CMD}" = "balena" ] &&
        [ -d "$inactive/docker" ]; then
            log "Removing leftover docker folder on a balena device"
            rm -rf "$inactive/docker"
    fi

    # Check leftover data on the Inactive partition, and clean up when found
    inactive_used=$(df "${inactive}" | grep "${inactive}" | awk '{ print $3}')
    # The empty/default storage space use is about 2200kb, so if more than that is in use, trigger cleanup
    if [ "$inactive_used" -gt "5000" ]; then
        hostapp_image_count=$(DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} images -q | wc -l)
        if [ "$hostapp_image_count" -eq "0" ]; then
            # There are no hostapp images, but space is still taken up
            local target_folder="${inactive}/${DOCKER_CMD}/"
            log "Found potential leftover data, cleaning ${target_folder}"
            systemctl stop "${DOCKER_CMD}-host"
            find "$target_folder" -mindepth 1 -maxdepth 1 -exec rm -r "{}" \; || true
            log "Inactive partition usage after cleanup: $(df -h "${inactive}" | grep "${inactive}" | awk '{ print $3}')"
            systemctl start "${DOCKER_CMD}-host"
            local timeout_iterations=0
            until DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} ps &> /dev/null; do sleep 0.2; if [ $((timeout_iterations++)) -ge 1500 ]; then log ERROR "${DOCKER_CMD}-host did not come up before check timed out..."; fi; done
        fi
    fi

    if [ "$STOP_ALL" = "yes" ]; then
        stop_services
        remove_containers
    fi
    log "Calling hostapp-update for ${update_package}"
    hostapp-update -i "${update_package}" && post_update_fixes
}

#######################################
# Query public apps for a matching image
# Globals:
#   APIKEY
#   API_ENDPOINT
#   SLUG
#   VARIANT (deprecated)
# Arguments:
#   version: the OS version to look for
# Returns:
#   Registry URL for desired image
#######################################
function get_image_location() {
    local variant_tag
    # we need to strip the target_version's variant tag to query the API properly
    local version=${1/.dev/}
    version=${version/.prod/}

    # TODO: Get the target variant from the raw version the user provided
    variant_tag=$(echo "${VARIANT:-production}" | tr "[:upper:]" "[:lower:]")

    image=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${APIKEY}" \
        "${API_ENDPOINT}/v6/release?\$select=id&\$expand=contains__image/image&\$filter=(belongs_to__application/any(a:a/is_for__device_type/any(dt:dt/slug%20eq%20'${SLUG}')%20and%20is_host%20eq%20true))%20and%20is_invalidated%20eq%20false%20and%20raw_version%20eq%20'${version}'" \
        | jq -r "[.d[] | .contains__image[0].image[0] | [.is_stored_at__image_location, .content_hash] | \"\(.[0])@\(.[1])\"]")
    if echo "${image}" | jq -e '. | length == 1' > /dev/null; then
        echo "${image}" | jq -r '.[0]'
    else
        # We still need to try finding the hostApp release by filtering using the deprecated release_tags,
        # since the versioning format of balenaOS [2019.10.0.dev, 2022.01.0] was non-semver compliant
        # and they were not migrated to the release semver fields.
        image=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${APIKEY}" \
            "${API_ENDPOINT}/v6/release?\$select=id&\$expand=contains__image/image&\$filter=(belongs_to__application/any(a:a/is_for__device_type/any(dt:dt/slug%20eq%20'${SLUG}')%20and%20is_host%20eq%20true))%20and%20is_final%20eq%20true%20and%20is_invalidated%20eq%20false%20and%20(release_tag/any(rt:(rt/tag_key%20eq%20'version')%20and%20(rt/value%20eq%20'${version}')))%20and%20((release_tag/any(rt:(rt/tag_key%20eq%20'variant')%20and%20(rt/value%20eq%20'${variant_tag}')))%20or%20not(release_tag/any(rt:rt/tag_key%20eq%20'variant')))" \
            | jq -r "[.d[] | .contains__image[0].image[0] | [.is_stored_at__image_location, .content_hash] | \"\(.[0])@\(.[1])\"]")
        if echo "${image}" | jq -e '. | length == 1' > /dev/null; then
            echo "${image}" | jq -r '.[0]'
        else
            # we should only get one result, something is wrong
            echo
        fi
    fi
}

#######################################
# Get a delta token
# Globals:
#   APIKEY
#   API_ENDPOINT
#   REGISTRY_ENDPOINT
#   UUID
# Arguments:
#   src: the source OS version location {registry}/{repo}:{hash}
#   dst: the target OS version location {registry}/{repo}:{hash}
# Returns:
#   JWT scoped to access desired delta image
#######################################
function get_delta_token() {
    src=$(echo "${1}" | awk -F@ '{print $1}' | sed -e 's/.*\/v2/v2/g')
    dst=$(echo "${2}" | awk -F@ '{print $1}' | sed -e 's/.*\/v2/v2/g')
    CURL_CA_BUNDLE="${TMPCRT}" ${CURL} \
        -u "d_${UUID}:${APIKEY}" \
        -H "Content-Type: application/json" \
        "${API_ENDPOINT}/auth/v1/token?service=${REGISTRY_ENDPOINT}&scope=repository:${dst}:pull&scope=repository:${src}:pull" \
        | jq -r '.token'
}

#######################################
# Find a delta in the registry between two hostapp versions using the API
# Globals:
#   APIKEY
#   DELTA_ENDPOINT
#   DELTA_VERSION
#   VERSION
# Arguments:
#   target_image: the desired OS version's balenaCloud image
# Returns:
#   Location of delta image
#######################################
function find_delta() {
    local target_image=${1}
    local src_image
    # shellcheck disable=SC2153
    src_image=$(get_image_location "${VERSION}")
    if [ -z "${src_image}" ]; then
        return
    else
        # TODO: should we retry this more extensively? deltas may take a while to generate..
        delta_token=$(get_delta_token "${src_image}" "${target_image}")
        delta=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} \
            "${DELTA_ENDPOINT}/api/v${DELTA_VERSION}/delta?src=${src_image}&dest=${target_image}" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${delta_token}" | jq -r '.name')
        if [ -n "${delta}" ]; then
            echo "${delta}"
        fi
    fi
}

#######################################
# Finish up the update process
# Clean up the update package (if needed), and reboot the device (if needed)
# Globals:
#   DOCKER_CMD
#   NOREBOOT
# Arguments:
#   update_package: the docker image to use for the update
# Returns:
#   None
#######################################
function finish_up() {
    update_package=$1
    # Clean up after the update if needed
    if [ -n "${update_package}" ] &&
        ${DOCKER_CMD} inspect "${update_package}" > /dev/null 2>&1 ; then
            log "Cleaning up update package: ${update_package}"
            ${DOCKER_CMD} rmi -f "${update_package}" || true
    else
        log "No update package cleanup done"
    fi

    sync

    DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} logout "${REGISTRY_ENDPOINT}" > /dev/null 2>&1 || true

    if [ "${NOREBOOT}" == "no" ]; then
        # Reboot into new OS
        log "Rebooting into new OS in 5 seconds..."
        progress 100 "Update successful, rebooting"
        if command -v /usr/libexec/safe_reboot > /dev/null; then
            systemd-run --on-active=5 --property=StandardError=append:"${LOGFILE}" --quiet --unit=hup-reboot.service /usr/libexec/safe_reboot
        else
            systemd-run --on-active=5 --quiet --unit=hup-reboot.service systemctl reboot
            # If the previous reboot command has failed for any reason, let's try differently
            (sleep 300 && nohup bash -c "reboot --force" > /dev/null 2>&1) &
            # If the previous 2 reboot commands have failed for any reason, try the Magic SysRq
            # enable and send reboot request
            (sleep 600 && echo 1 > /proc/sys/kernel/sysrq && echo b > /proc/sysrq-trigger) &
        fi
    else
        log "Finished update, not rebooting as requested."
        progress 100 "Update successful pending reboot."
    fi
    rm -f "${TMPCRT}" > /dev/null 2>&1
    exit 0
}

function post_update_fixes() {
    case ${SLUG} in
        jetson-tx2)
            log "Running post-update fixes for ${SLUG}"
            if [[ -n "${JETSON_FIX}" && "${JETSON_FIX}" -eq 1 ]]; then
                post_update_jetson_fix
            fi
            # required for the supervisor to take control, see https://github.com/balena-os/balenahup/issues/328
            touch /mnt/boot/extra_uEnv.txt
            ;;
        *)
            log "No device-specific pre-update fix for ${SLUG}"
    esac
}

###
# Script start
#
# There are two patterns of required input arguments to invoke this script:
# --hostos-version, --balenaos-registry
#   Used by balenaProxy push to device. Queries for target image URI.
#
# --app-uuid, --release-commit, --target-image-uri (optional)
#   Used by Supervisor pull from balenaCloud. Queries for target version, and
#   target-image-uri as needed, and parses registry from the target URI.
#
# Note: --target-image-uri value may not be stable long-term, so we cannot use
# it alone as the source of target version.
###

# If no arguments passed, just display the help
if [ $# -eq 0 ]; then
    help
    exit 0
fi
# Log timer
starttime=$(date +%s)

# For compatibility purposes
if [ -d "/mnt/data/resinhup" ] && [ ! -e "/mnt/data/balenahup" ]; then
    ln -s "/mnt/data/resinhup" "/mnt/data/balenahup"
fi
# LOGFILE init and header
LOGFILE="/mnt/data/balenahup/$SCRIPTNAME.$(date +"%Y%m%d_%H%M%S").log"
mkdir -p "$(dirname "$LOGFILE")"
log "================$SCRIPTNAME HEADER START====================" > "$LOGFILE"
date >> "$LOGFILE"

log "Loading info from config.json"
if [ -f /mnt/boot/config.json ]; then
    CONFIGJSON=/mnt/boot/config.json
else
    log "Don't know where config.json is." && exit 1
fi
# If the user api key exists we use it instead of the deviceApiKey as it means we haven't done the key exchange yet
APIKEY=$(jq -r '.apiKey // .deviceApiKey' $CONFIGJSON)
UUID=$(jq -r '.uuid' $CONFIGJSON)
API_ENDPOINT=$(jq -r '.apiEndpoint' $CONFIGJSON)
DELTA_ENDPOINT=$(jq -r '.deltaEndpoint' $CONFIGJSON)

[ -z "${APIKEY}" ] && log "Error parsing config.json" && exit 1
[ -z "${UUID}" ] && log "Error parsing config.json" && exit 1
[ -z "${API_ENDPOINT}" ] && log "Error parsing config.json" && exit 1
[ -z "${DELTA_ENDPOINT}" ] && log "Error parsing config.json" && exit 1

_err_handler(){
    log ERROR "Interrupted on error"
}

_int_handler(){
    log ERROR "Interrupted"
}

_term_handler(){
    log ERROR "Terminated"
}

trap '_err_handler' ERR
trap '_int_handler' INT
trap '_term_handler' TERM

# redirect all logs to the logfile, but also stderr to console (proxy)
outfifo=$(mktemp -u)
errfifo=$(mktemp -u)
mkfifo "${outfifo}" "${errfifo}"
# Read from the stdout FIFO and append to LOGFILE
cat "${outfifo}" >> "${LOGFILE}" &
# Read from the stderr FIFO, append to LOGFILE, and also display to terminal's stderr
tee -a "${LOGFILE}" < "${errfifo}" >&2 &
# Redirect script's stdout and stderr to the respective FIFOs
exec >"${outfifo}" 2>"${errfifo}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    arg="$1"

    case $arg in
        -h|--help)
            help
            exit 0
            ;;
        --app-uuid)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            app_uuid=$2
            shift
            ;;
        --force-slug)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            FORCED_SLUG=$2
            shift
            ;;
        --hostos-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            target_version=$2
            log "Raw target version: ${target_version}"
            case $target_version in
                *.prod)
                    target_version="${target_version%%.prod}"
                    log "Normalized target version: ${target_version}"
                    ;;
            esac
            shift
            ;;
        --release-commit)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            release_commit=$2
            shift
            ;;
        --resinos-registry | --balenaos-registry)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            REGISTRY_ENDPOINT=$2
            shift
            ;;
        --supervisor-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            target_supervisor_version=$2
            shift
            ;;
        --no-reboot)
            NOREBOOT="yes"
            ;;
        --stop-all)
            STOP_ALL="yes"
            ;;
        --target-image-uri)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            target_image=$2
            shift
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

# Enforce required arguments. See comment above at 'Script start'.
if [ -z "$target_version" ] && [ -z "$app_uuid" ]; then
    log ERROR "Either --hostos-version or --app-uuid is required."
fi
if [ -n "$target_version" ] && [ -n "$app_uuid" ]; then
    log ERROR "Only one of --hostos-version and --app-uuid may be specified."
fi
if [ -n "$target_version" ] && [ -z "${REGISTRY_ENDPOINT}" ]; then
    log ERROR "--balenaos-registry is required."
fi
if [ -n "$app_uuid" ] && [ -z "$release_commit" ]; then
    log ERROR "--release-commit is required."
fi
if [ -z "$app_uuid" ] && [ -n "$target_image" ]; then
    log ERROR "--target-image-uri is useful only with --app-uuid."
fi

progress 25 "Preparing OS update"


FETCHED_SLUG=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} -H "Authorization: Bearer ${APIKEY}" \
"${API_ENDPOINT}/v6/device?\$select=is_of__device_type&\$expand=is_of__device_type(\$select=slug)&\$filter=uuid%20eq%20%27${UUID}%27" 2>/dev/null \
| jq -r '.d[0].is_of__device_type[0].slug'
)

SLUG=${FORCED_SLUG:-$FETCHED_SLUG}
HOST_OS_VERSION=${META_BALENA_VERSION:-${VERSION_ID}}

# Check host OS version
case $VERSION in
    [2-9].*|2[0-9][0-9][0-9].*.*)
        if version_gt "$minimum_hostos_version" "$VERSION"; then
            log ERROR "Host OS version \"$VERSION\" < \"$minimum_hostos_version\", not supported."
        fi
        log "Host OS version \"$VERSION\" OK."
        ;;
    *)
        log ERROR "Host OS version \"$VERSION\" not supported."
        ;;
esac

# Must query for target version and perhaps for target image, which includes registry
# endpoint, if started from app UUID.
if [ -n "$app_uuid" ]; then
    # Retrieve version for the provided app UUID and release commit. Verify that
    # the release succeeded and has not been invalidated. We expect at most a
    # single release. Catch command failure for handling below.
    _query_res=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} \
        -H "Content-Type: application/json" -H "Authorization: Bearer ${APIKEY}" \
        "${API_ENDPOINT}/v7/release?\$select=raw_version&\$filter=commit%20eq%20%27${release_commit}%27%20and%20(belongs_to__application/any(bta:bta/is_host%20and%20bta/uuid%20eq%20%27${app_uuid}%27))%20and%20status%20eq%20'success'%20and%20is_invalidated%20eq%20false" || echo "fail")

    # Verify the result includes a json row.
    _has_row=$(echo "${_query_res}" | jq -r ".d[]" || echo "")
    if [ -z "$_has_row" ]; then
        if [ "${_query_res}" = "fail" ]; then
            log ERROR "Target release query from app UUID failed"
        else
            log ERROR "Target release query from app UUID not found or not valid"
        fi
    fi
    target_version=$(echo "${_query_res}" | jq -r ".d[] | .raw_version")

    # We do not expect registry endpoint is defined separately, so must query
    # for optional target image here if not defined already -- so we can parse
    # for the endpoint below.
    if [ -z "${target_image}" ]; then
        target_image=$(get_image_location "${target_version}")
        if [ -z "${target_image}" ]; then
            log ERROR "Zero or multiple matching target hostapp releases found, update attempt has failed..."
        fi
    fi

    # Not expecting a backslash in domain name, so:
    # shellcheck disable=SC2162
    read -d "/" REGISTRY_ENDPOINT <<<"$target_image"    
    if [ -z "${REGISTRY_ENDPOINT}" ] || [ "${REGISTRY_ENDPOINT}" = "${target_image}" ]; then
        log ERROR "Target image URI expected '/': ${target_image}"
    fi
    log "Registry endpoint from target release: ${REGISTRY_ENDPOINT}"
fi

if [ -n "$target_version" ]; then
    case $target_version in
        [2-9].*|2[0-9][0-9][0-9].*.*)
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

if [ "${SLUG}" = "raspberrypi4-64" ] && \
    [ "${target_version}" = "2.83.10+rev1" ] ; then
    board_rev="$(awk '{print $NF}' < /proc/device-tree/model)"
    if [ "${board_rev}" = "1.4" ] ; then
        log ERROR "Upgrading to release 2.83.10+rev1 is disabled for Raspberry Pi 4 Model B Rev 1.4 due to an EEPROM issue"
    fi
fi

# Already retrieved if script inputs from App UUID and release commit.
if [ -z "${target_image}" ]; then
    target_image=$(get_image_location "${target_version}")
    if [ -z "${target_image}" ]; then
        log ERROR "Zero or multiple matching target hostapp releases found, update attempt has failed..."
    fi
fi

log "Attempting host OS update using deltas"
delta_image=$(find_delta "${target_image}")

if [ -n "${delta_image}" ]; then
    delta_size=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} -H "Authorization: Bearer ${APIKEY}" \
    "${API_ENDPOINT}/v5/delta?\$filter=((status%20eq%20'success')%20and%20(version%20eq%20'${DELTA_VERSION}')%20and%20(is_stored_at__location%20eq%20'${delta_image}'))" 2>/dev/null \
    | jq -r '.d[0].size|tonumber / (1024.0 * 1024.0) | floor' 2>/dev/null || /bin/true)
    log "Found delta image: ${delta_image}, size: ${delta_size:-unknown} MB"

else
    log "No delta found, falling back to regular pull"
fi

log "hostapp-update command exists, use that for update"
progress 50 "Running OS update"
images=("${delta_image}" "${target_image}")
# record the "source" of each image in the array above for clarity during fallback
image_types=("delta" "balena_registry")
update_failed=0
# login for private device types
DOCKER_HOST="unix:///var/run/${DOCKER_CMD}-host.sock" ${DOCKER_CMD} login "${REGISTRY_ENDPOINT}" -u "d_${UUID}" \
--password "${APIKEY}" > /dev/null 2>&1 || log WARN "logging into registry failed, proceeding anyway (only required for private device types)"
for img in "${images[@]}"; do
    if [ -n "${img}" ] && hostapp_based_update "${img}"; then
        # once we've updated successfully, set our canonical image
        image=${img}
        break
    else
        log "Image type ${image_types[${update_failed}]}, location '${img}' failed or not found, trying another source"
        update_failed=$(( update_failed + 1 ))
    fi
done
if [ -z "${image}" ]; then
    log ERROR "all hostapp-update attempts have failed..."
fi

upgrade_supervisor "${image}"
finish_up "${image}"
