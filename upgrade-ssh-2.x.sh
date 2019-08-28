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
        WARNING: this flag has been deprecated for this script, set --resinos-repo
        to set the location of the staging resinOS images.
        For backwards compatibility, this flag acts the same as
        --resinos-repo resin/resinos-staging

  -u <UUID>, --uuid <UUID>
        Update this UUID. Multiple -u can be provided to updated mutiple devices.

  -s <SSH_HOST>, --ssh-host <SSH_HOST>
        SSH host to be used in ssh connections (e.g. resin or resinstaging).

  -m <MAX_THREADS>, --max-threads <MAX_THREADS>
        Maximum number of threads to be used when updating devices in parallel. Useful to
        not network bash network if devices are in the same one. If value is 0, all
        updates will start in parallel.

  --force-slug <SLUG>
        Run ${main_script_name} with --force-slug <SLUG>
        See ${main_script_name} help for more details.

  --hostos-version <HOSTOS_VERSION>
        Run ${main_script_name} with --hostos-version <HOSTOS_VERSION>, use e.g. 2.2.0+rev1
        See ${main_script_name} help for more details.
        This is a mandatory argument.

  --resinos-registry <REGISTRY>
       Run ${main_script_name} with --resinos-registry <REGISTRY>, e.g. 'registry.hub.docker.com'
       See ${main_script_name} help for more details.

  --resinos-repo <REPOSITORY>
        Run ${main_script_name} with --resinos-repo <REPOSITORY>, e.g. 'resin/resinos'
        See ${main_script_name} help for more details.

  --resinos-tag <TAG>
        Run ${main_script_name} with --resinos-tag <TAG>, e.g. '2.9.5_rev1-raspberrypi3'
        See ${main_script_name} help for more details.

  --supervisor-version <SUPERVISOR_VERSION>
        Run ${main_script_name} with --supervisor-version <SUPERVISOR_VERSION>, use e.g. 6.2.5
        See ${main_script_name} help for more details.

  --stop-all
        Run ${main_script_name} with --stop-all, to stop running containers before the update.

  --ignore-sanity-checks
        Run ${main_script_name} with --ignore-sanity-checks
        See ${main_script_name} help for more details.

  --assume-supported
        Run ${main_script_name} with --assume-supported
        See ${main_script_name} help for more details.

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

# The script running the update on the device
UPDATE_SCRIPT="$SCRIPTPATH/${main_script_name}"

# Log timer
STARTTIME=$(date +%s)

# If no arguments passed, just display the help
if [ $# -eq 0 ]; then
    help
    exit 0
fi
# Parse arguments
while [[ $# -gt 0 ]]; do
    arg="$1"

    case $arg in
        -h|--help)
            help
            exit 0
            ;;
        --staging)
            log WARN "--staging has been deprecated, in the future --resinos-repo to set the right place to pull the images from."
            RESINHUP_ARGS+=( "--staging" )
            ;;
        --ignore-sanity-checks)
            RESINHUP_ARGS+=( "--ignore-sanity-checks" )
            ;;
        --assume-supported)
            RESINHUP_ARGS+=( "--assume-supported" )
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
        --force-slug)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            SLUG=$2
            RESINHUP_ARGS+=( "--force-slug $SLUG" )
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
        --resinos-registry)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            RESINOS_REGISTRY=$2
            RESINHUP_ARGS+=( "--resinos-registry $RESINOS_REGISTRY" )
            shift
            ;;
        --resinos-repo)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            RESINOS_REPO=$2
            RESINHUP_ARGS+=( "--resinos-repo $RESINOS_REPO" )
            shift
            ;;
        --resinos-tag)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            RESINOS_TAG=$2
            RESINHUP_ARGS+=( "--resinos-tag $RESINOS_TAG" )
            shift
            ;;
        --stop-all)
            RESINHUP_ARGS+=( "--stop-all" )
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
        --no-colors)
            NOCOLORS=yes
            ;;
        *)
            log WARN "Unrecognized option $1."
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

    if ! ssh "$SSH_HOST" host -s "${uuid}" "exit"> /dev/null 2>&1; then
        log WARN "[$CURRENT_UPDATE/$NR_UPDATES] Can't connect to device. Skipping..."
        continue
    fi

    # Connect to device
    echo "Running ${main_script_name} ${RESINHUP_ARGS[*]} ..." >> "$log_filename"
    ssh "$SSH_HOST" host -s "${uuid}" "bash -s" -- "${RESINHUP_ARGS[@]}"  < "${UPDATE_SCRIPT}" >> "$log_filename" 2>&1 &

    # Manage queue of threads
    PID=$!
    addtoqueue "$PID:$uuid"
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
