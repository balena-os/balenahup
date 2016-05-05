#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m'
TAG=latest

# Help function
function help {
    cat << EOF
Run docker build and push for the supported images.
$0 <OPTION>

Options:
  -h, --help
        Display this help and exit.

  -d, --dockerfile
        Build and push only this Dockerfile. Otherwise all found will be used.

  -t, --tag
        By default push will be done to latest tag. This can be tweaked with this flag.

EOF
}

#
# MAIN
#

# Parse arguments
while [[ $# > 0 ]]; do
    arg="$1"

    case $arg in
        -h|--help)
            help
            exit 0
            ;;
        -d|--dockerfile)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            DOCKERFILES=$2
            shift
            ;;
        -t|--tag)
            if [ -z "$2" ]; then
                log ERROR "\"$1\" argument needs a value."
            fi
            TAG=$2
            shift
            ;;
        *)
            log ERROR "Unrecognized option $1."
            ;;
    esac
    shift
done

# Get the absolute script location
pushd `dirname $0` > /dev/null 2>&1
SCRIPTPATH=`pwd`
popd > /dev/null 2>&1

if [ -z "$DOCKERFILES" ]; then
    DOCKERFILES=$(ls $SCRIPTPATH/../Dockerfile.*)
fi

for dockerfile in $DOCKERFILES; do
    dockerfile=$(basename $dockerfile)
    device=$(echo $dockerfile | cut --delimiter '.' -f2)
    if [ -z "$device" ]; then
        echo "ERROR: Can't detect device name for $dockerfile"
        exit 1
    fi
    printf "${GREEN}Running build for $device using $dockerfile ...${NC}\n"
    docker build -t resinhup-$device:$TAG -f ../$dockerfile $SCRIPTPATH/..
    printf "${GREEN}Tag an push for $device ...${NC}\n"
    docker tag -f resinhup-$device registry.resinstaging.io/resinhup/resinhup-$device:$TAG
    docker push registry.resinstaging.io/resinhup/resinhup-$device:$TAG
done
