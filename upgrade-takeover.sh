#!/bin/bash
#
# Upgrades balenaOS version by running takeover to flash storage, potentially
# including repartitioning. See https://github.com/balena-os/takeover
#
# Arguments:
#  * --hostos-version is required to specify target OS version
#  * See help() below for details
#
# Outputs:
#  * Writes log file to /mnt/boot/balenahup
#  * Notifies balenaAPI by PATCHing the device via /usr/bin resin-device-progress script
#
# Results:
#  * Flashes new OS and reboots into it on success
#  * Returns 9 if another upgrade script may already be running
#  * Returns 1 on other errors in this script
#  * Reboots into current OS if fails later in the attempt
#
# Notes:
# This script was derived from upgrade-2.x.sh for traditional balenahup upgrades.
#
# Variable SLUG (device type) is read from /etc/os-release, but unused here.
# The upgrade-2.x.sh script retrieves the slug from the backend API or allows
# specifying it as an argument to the script. Reinstate those mechanisms if we
# need that value, for example to change device type (Intel NUC -> Generic amd64).
#

SCRIPTNAME=upgrade-takeover.sh

# Set up cautious error handling, run ERR trap on failure
set -o errexit
set -E
set -o pipefail

# Define variables about running balenaOS, including VERSION and SLUG (device type)
# shellcheck disable=SC1091
source /etc/os-release

# Set PATH for binary lookups
# shellcheck disable=SC1091
source /etc/profile

# Prevent running multiple instances of upgrade
LOCKFILE="/var/lock/resinhup.lock"
LOCKFD=99
# Private functions
_lock()             { flock "-$1" $LOCKFD; }
_exit_handler() {
    _exit_status=$?
    if [ "${_exit_status}" -ne 0 ]; then
        log "Exit on error ${_exit_status}"
        if ! report_upgrade_failed > /dev/null 2>&1; then
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

# Helper function to report progress to device API
# $1 -- integer: completion percentage
# $2 -- string: detail message
function progress {
    pct=$1
    message=$2
    resin-device-progress --percentage "${pct}" --state "${message}" > /dev/null || true
}

function help {
    cat << EOF
Upgrade balenaOS via takeover tool

Options:
  -h, --help
        Display this help and exit.

  --force-slug <SLUG>
        Override slug detection and force this slug to be used for the script.

  --hostos-version <HOSTOS_VERSION>
        Run the updater for this specific HostOS version as semver or ESR, where
        semver is in the format major.minor.patch, like 2.5.1; and ESR is in the
        format year.month.patch, like 2024.4.0. The version must begin with a
        digit, not a 'v'. This is a mandatory argument.
EOF
}

# Notify backend device API that upgrade has failed. This report is essential
# to allow a user to retry the upgrade. Sends the report, and then independently
# verifies success. Tries once per minute for an hour.
function report_upgrade_failed() {
    pct=100
    state="OS update failed"
    while ! compare_device_state "${pct}" "${state}"; do
        ((c++)) && ((c==60)) && break
        if resin-device-progress --percentage "${pct}" --state "${state}"; then
            continue
        fi
        log WARN "Retrying failure report - try $c"
        sleep 60
    done
}

# Log operational message; writes provided text to journal and echos to stdout.
# If log at ERROR level, exits this script with code 1.
#
# $1 -- optional log level, must be ERROR or WARN; otherwise defaults to INFO
# $2 -- log message
function log {
    # Process log level if provided to function
    priority=6
    case $1 in
        ERROR)
            loglevel=ERROR
            # 3 is "err"
            priority=3
            shift
            ;;
        WARN)
            loglevel=WARNING
            # 4 is "warning"
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

# Test if the first arg is greater than the second, when the args are compared
# as semvers.
# Return 0 if the first item is greater; 1 otherwise
# For example, version_gt "1.2.10" "1.2.3" returns true.
#
# $1 -- expected greater version
# $2 -- version to compare
function version_gt() {
    test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"
}

# Compare the provided percentage and state values with backend device API
# provisioning_progress and provisioning_state.
# Return 0 if the values are equal; otherwise return 1
function compare_device_state() {
    pct=$1
    state=$2
    resp=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} --header "Authorization: Bearer ${APIKEY}" \
        "${API_ENDPOINT}/v6/device(uuid='${UUID}')?\$select=provisioning_state,provisioning_progress" | jq '.d[]')
    remote_pct=$(echo "${resp}" | jq -r '.provisioning_progress')
    remote_state=$(echo "${resp}" | jq -r '.provisioning_state')
    if [ -n "${remote_pct}" ] && [ -n "${remote_state}" ]; then
        test "${pct}" -eq "${remote_pct}" && test "${state}" = "${remote_state}"
    else
        return 1
    fi
}

# Stop Supervisor and related systemd services
function stop_services() {
    log "Stopping supervisor and related services..."
    systemctl stop update-balena-supervisor.timer > /dev/null 2>&1 || systemctl stop update-resin-supervisor.timer > /dev/null 2>&1
    systemctl stop balena-supervisor  > /dev/null 2>&1 || systemctl stop resin-supervisor > /dev/null 2>&1
    ${DOCKER_CMD} rm -f balena_supervisor resin_supervisor > /dev/null 2>&1 || true
}

# Remove and log fsck recovery files. Since takeover will reflash the disk, it's
# not strictly necessary. However, it may indicate issues with the storage medium,
# so good to know.
function remove_rec_files() {
    local boot_dir='/mnt/boot'
    shopt -s nullglob
    for f in "${boot_dir}"/*.REC; do
        log WARN "Removing $f from boot partition"
        rm -f "$f"
    done
    sync ${boot_dir}
}

# Download takeover tool binary for device's architecture
# Requires $takeover_path
# Exits script on download failure
function download_takeover_binary() {
    architecture=$(uname -m)
    case ${architecture} in
        aarch64|x86_64)
            log "Using takeover arch ${architecture}"
            ;;
        *)
            log ERROR "Takeover binary for arch: ${architecture} not found"
    esac

    download_url="https://github.com/balena-os/takeover/releases/download/v0.8.3/takeover-${architecture}-unknown-linux-musl.tar.gz"
    log "Downloading takeover binary ${download_url}"

    ${CURL} -o "${takeover_path}/takeover.tar.gz" $download_url || log ERROR "Could not download takeover binary, aborting."

    # Extract and prepare for use
    tar -C "${takeover_path}" -zxvf "${takeover_path}/takeover.tar.gz"
    chown root:root "${takeover_path}/takeover"
    rm "${takeover_path}/takeover.tar.gz"
}

# Download target balenaOS image; expects a public image
# Requires:
#   $target_version; already verified
#   $SLUG; already verified
#   #takeover_page; already verified
# Exits script on download failure
function download_target_image() {
    log "Downloading target image"
    # Don't use --fail; we want the status code
    curl_no_fail="curl --silent --retry 10 --location --compressed"

    status_code=$(\
        CURL_CA_BUNDLE="${TMPCRT}" ${curl_no_fail} -H "Authorization: Bearer ${APIKEY}" \
            -H "Content-Type: application/json" -w "%{http_code}" \
            --output "${takeover_path}/balenaos.img.gz" \
            "${API_ENDPOINT}/downloa?deviceType=${SLUG}&version=${target_version}&fileType=.gz" \
             2>/dev/null \
         )
    if [ -n "${status_code}" ]; then
        # expecting 200
        if [ "${status_code:0:1}" == "2" ]; then
            log "Download image success; code: ${status_code}"
        else
            log ERROR "Download image failed; code: ${status_code}"
        fi
    else
        log WARN "Download image; no status code"
    fi
    # sanity check
    if [ ! -f "${takeover_path}/balenaos.img.gz" ]; then
        log ERROR "Target image not found"
    fi
}


###
# Script start
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
    log ERROR "Can't find config.json"
fi
# Use the user's api key if it exists rather than deviceApiKey; it means we haven't
# done the key exchange yet.
APIKEY=$(jq -r '.apiKey // .deviceApiKey' $CONFIGJSON)
UUID=$(jq -r '.uuid' $CONFIGJSON)
API_ENDPOINT=$(jq -r '.apiEndpoint' $CONFIGJSON)
DELTA_ENDPOINT=$(jq -r '.deltaEndpoint' $CONFIGJSON)

[ -z "${APIKEY}" ] && log "Error parsing config.json" && exit 1
[ -z "${UUID}" ] && log "Error parsing config.json" && exit 1
[ -z "${API_ENDPOINT}" ] && log "Error parsing config.json" && exit 1
[ -z "${DELTA_ENDPOINT}" ] && log "Error parsing config.json" && exit 1

# Create a certificate bundle file incorporating any CA provided in config.json.
# We create this primarily for use by curl. The OS started integrating this CA
# with v2.58, but use this variable in case we have an older version.
TMPCRT=$(mktemp)
jq -r '.balenaRootCA' < ${CONFIGJSON} | base64 -d > "${TMPCRT}"
cat /etc/ssl/certs/ca-certificates.crt >> "${TMPCRT}"

# Set up curl for use within a script, retry many times for reliability, follow
# redirects, and compress responses.
CURL="curl --silent --retry 10 --fail --location --compressed"

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

if [ -x "$(command -v balena)" ]; then
    DOCKER_CMD="balena"
else
    DOCKER_CMD="docker"
fi

# Redirect all logs to the logfile
outfifo=$(mktemp -u)
errfifo=$(mktemp -u)
mkfifo "${outfifo}" "${errfifo}"
# Read from the stdout FIFO and append to LOGFILE
cat "${outfifo}" >> "${LOGFILE}" &
# Read from the stderr FIFO, append to LOGFILE, and also display to terminal's stderr
cat "${errfifo}" >> "${LOGFILE}" &
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
        *)
            log WARN "Unrecognized option $1."
            ;;
    esac
    shift
done

# Run on start
_prepare_locking
# Try to get the lock. Exit if unable; another instance is running already.
exlock_now || exit 9

if [ -z "$target_version" ]; then
    log ERROR "--hostos-version is required."
fi

progress 25 "Preparing OS update"

# Retrieve slug (device type) from API, and use this value if not provided to  the script.
# Verify this call succeeds?
FETCHED_SLUG=$(CURL_CA_BUNDLE="${TMPCRT}" ${CURL} -H "Authorization: Bearer ${APIKEY}" \
    "${API_ENDPOINT}/v6/device?\$select=is_of__device_type&\$expand=is_of__device_type(\$select=slug)&\$filter=uuid%20eq%20%27${UUID}%27" 2>/dev/null \
    | jq -r '.d[0].is_of__device_type[0].slug'
    )

SLUG=${FORCED_SLUG:-$FETCHED_SLUG}

# Validate target version in semver (major > 1) or year.month.patch format
if [ -n "$target_version" ]; then
    case $target_version in
        [2-9].*|[1-9][0-9].*|2[0-9][0-9][0-9].*.*)
            log "Target OS version \"$target_version\" OK."
            ;;
        *)
            log ERROR "Target OS version \"$target_version\" not supported."
            ;;
    esac
else
    log ERROR "No target OS version specified."
fi

# Validate host OS version, similar to target_version above
case $VERSION in
    [2-9].*|[1-9][0-9].*|2[0-9][0-9][0-9].*.*)
        log "Host OS version \"$VERSION\" OK."
        ;;
    *)
        log ERROR "Host OS version \"$VERSION\" not supported."
        ;;
esac

# Ensure takeover environment is prepared
takeover_path="/mnt/data/takeover"
mkdir -p "${takeover_path}"

# Download target hostOS image as required
if [ ! -f "${takeover_path}/balenaos.img.gz" ]; then
    download_target_image
else
    log "balenaOS target image available; download not required"
fi

# Download takeover binary as required
if [ ! -f "${takeover_path}/takeover" ]; then
    download_takeover_binary
else
    log "Takeover binary available; download not required"
fi

progress 50 "Running OS update"

# Run takeover
# Must run from a writable directory; takeover creates temp files there
cd ${takeover_path}

# No need to specify config.json path; defaults to /mnt/boot.
# API check fails on BoB, so disabled
res=$(./takeover -i balenaos.img.gz \
   --no-ack --no-nwmgr-check --no-os-check --no-vpn-check \
   --log-level debug -l /dev/sda1 --s2-log-level debug)
log ERROR "Takeover result ${res}; OS not updated"
