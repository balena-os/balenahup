#!/bin/bash

main_script_name="upgrade-2.x.sh"
RESINHUP_ARGS=()
UUIDS=""
SSH_HOST=""
NOCOLORS=no
FAILED=0

NUM=0
QUEUE=""
MAX_THREADS=5

# Help function
function help {
    cat << EOF
Wrapper to run host OS updates on fleet of devices over ssh.
$0 <OPTION>

Options:
  -h, --help
        Display this help and exit.

  --staging
        Do this update for devices in staging.
        By default resinhup assumes the devices are in production.

  -u <UUID>, --uuid <UUID>
        Update this UUID. Multiple -u can be provided to updated mutiple devices.

  -s <SSH_HOST>, --ssh-host <SSH_HOST>
        SSH host to be used in ssh connections (e.g. resin or resinstaging).

  -m <MAX_THREADS>, --max-threads <MAX_THREADS>
        Maximum number of threads to be used when updating devices in parallel. Useful to
        not network bash network if devices are in the same one. If value is 0, all
        updates will start in parallel.

  --hostos-version <HOSTOS_VERSION>
        Run ${main_script_name} with --hostos-version <HOSTOS_VERSION>, use e.g. 2.2.0+rev1
        See ${main_script_name} help for more details.
        This is a mandatory argument.

  --supervisor-version <SUPERVISOR_VERSION>
        Run ${main_script_name} with --supervisor-version <SUPERVISOR_VERSION>, use e.g. 6.2.5
        See ${main_script_name} help for more details.

  --ignore-sanity-checks
        Run ${main_script_name} with --ignore-sanity-checks
        See ${main_script_name} help for more details.

  --nolog
        Run ${main_script_name} with --nolog
        See ${main_script_name} help for more details. For running over ssh this is likely
        recommended, as otherwise the log is just kept on the device, the local log
        on the computer running the remote updater script will have only log headers.

  --no-reboot
        Run ${main_script_name} with --no-reboot . See ${main_script_name} help for more details.

  --no-colors
        Avoid terminal colors.
EOF
}

# Log function helper
function log {
    local COL
    local COLEND='\e[0m'
    local loglevel=LOG

    case $1 in
        ERROR)
            COL='\e[31m'
            loglevel=ERR
            shift
            ;;
        WARN)
            COL='\e[33m'
            loglevel=WRN
            shift
            ;;
        SUCCESS)
            COL='\e[32m'
            loglevel=LOG
            shift
            ;;
        *)
            COL=$COLEND
            loglevel=LOG
            ;;
    esac

    if [ "$NOCOLORS" == "yes" ]; then
        COLEND=''
        COL=''
    fi

    ENDTIME=$(date +%s)
    printf "${COL}[%09d%s%s${COLEND}\n" "$((ENDTIME - STARTTIME))" "][$loglevel]" "$1"
    if [ "$loglevel" == "ERR" ]; then
        exit 1
    fi
}

cleanstop() {
    log WARN "Force close requested. Waiting for already started updates... Please wait!"
    while [ -n "$QUEUE" ]; do
        checkqueue
        sleep 0.5
    done
    wait
    log ERROR "Forced stop."
    exit 1
}
trap 'cleanstop' SIGINT SIGTERM

function addtoqueue {
    NUM=$((NUM+1))
    QUEUE="$QUEUE $1"
}

function regeneratequeue {
    OLDREQUEUE=$QUEUE
    QUEUE=""
    NUM=0
    for entry in $OLDREQUEUE; do
        PID=$(echo "$entry" | cut -d: -f1)
        if [ -d "/proc/$PID"  ] ; then
            QUEUE="$QUEUE $entry"
            NUM=$((NUM+1))
        fi
    done
}

function checkqueue {
    OLDCHQUEUE=$QUEUE
    for entry in $OLDCHQUEUE; do
        local _PID
        _PID=$(echo "$entry" | cut -d: -f1)
        if [ ! -d "/proc/$_PID" ] ; then
            wait "$_PID"
            local _exitcode=$?
            local _UUID
            _UUID=$(echo "$entry" | cut -d: -f2)
            if [ "$_exitcode" != "0" ]; then
                log WARN "Updating $_UUID failed."
                FAILED=1
            else
                log SUCCESS "Updating $_UUID succeeded."
            fi
            regeneratequeue
            break
        fi
    done
}

#
# MAIN
#

# Get the absolute script location
pushd "$(dirname "$0")" > /dev/null 2>&1
SCRIPTPATH=$(pwd)
popd > /dev/null 2>&1

# Tools we need on device
UPDATE_TOOLS=(
"$SCRIPTPATH/${main_script_name}"
)

# Log timer
STARTTIME=$(date +%s)

# Parse arguments
while [[ $# -gt 0 ]]; do
    arg="$1"

    case $arg in
        -h|--help)
            help
            exit 0
            ;;
        --staging)
            RESINHUP_ARGS+=( "--staging" )
            ;;
        --ignore-sanity-checks)
            RESINHUP_ARGS+=( "--ignore-sanity-checks" )
            ;;
        -u|--uuid)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            UUIDS="$UUIDS $2"
            shift
            ;;
        -s|--ssh-host)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            SSH_HOST=$2
            shift
            ;;
        -m|--max-threads)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            MAX_THREADS=$2
            shift
            ;;
        --hostos-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            HOSTOS_VERSION=$2
            RESINHUP_ARGS+=( "--hostos-version $HOSTOS_VERSION" )
            shift
            ;;
        --supervisor-version)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            SUPERVISOR_VERSION=$2
            RESINHUP_ARGS+=( "--supervisor-version $SUPERVISOR_VERSION" )
            shift
            ;;
        --no-reboot)
            RESINHUP_ARGS+=( "--no-reboot" )
            ;;
        --nolog)
            RESINHUP_ARGS+=( "--nolog" )
            ;;
        --no-colors)
            NOCOLORS=yes
            ;;
        *)
            log ERROR "Unrecognized option $1."
            ;;
    esac
    shift
done

# Check argument(s)
if [ -z "$UUIDS" ] || [ -z "$SSH_HOST" ]; then
    log ERROR "No UUID and/or SSH_HOST specified."
fi

CURRENT_UPDATE=0
NR_UPDATES=$(echo "$UUIDS" | wc -w)

# 0 threads means Parallelise everything
if [ "$MAX_THREADS" -eq 0 ]; then
    MAX_THREADS=$NR_UPDATES
fi

# Update each UUID
for uuid in $UUIDS; do
    CURRENT_UPDATE=$((CURRENT_UPDATE+1))

    log "[$CURRENT_UPDATE/$NR_UPDATES] Updating $uuid on $SSH_HOST."
    log_filename="$uuid.upgrade2x.log"

    if ! ssh "$SSH_HOST" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o "Hostname=${uuid}.vpn" exit > /dev/null 2>&1; then
        log WARN "[$CURRENT_UPDATE/$NR_UPDATES] Can't connect to device. Skipping..."
        continue
    fi

    # Transfer the scripts
    if ! scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o Hostname="${uuid}.vpn" "${UPDATE_TOOLS[@]}" "$SSH_HOST":/tmp/ > "$log_filename" 2>&1; then
        log WARN "[$CURRENT_UPDATE/$NR_UPDATES] Could not scp needed tools to device. Skipping..."
        continue
    fi

    # Connect to device
    echo "Running run-resinhup.sh ${RESINHUP_ARGS[*]} ..." >> "$log_filename"
    ssh "$SSH_HOST" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o Hostname="${uuid}.vpn" "/tmp/${main_script_name}" "${RESINHUP_ARGS[@]}" >> "$log_filename" 2>&1 &

    # Manage queue of threads
    PID=$!
    addtoqueue $PID:$uuid
    while [ "$NUM" -ge "$MAX_THREADS" ]; do
        checkqueue
        sleep 0.5
    done
done

# Wait for all threads
log "Waiting for all threads to finish..."
while [ -n "$QUEUE" ]; do
    checkqueue
    sleep 0.5
done
wait

if [ $FAILED -eq 1 ]; then
    log ERROR "At least one device failed to update."
fi

# Success
exit 0
