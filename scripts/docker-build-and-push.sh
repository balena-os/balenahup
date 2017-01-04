#!/bin/bash

set -e

readonly _registry_paths_default="registry.resinstaging.io/resin/resinhup resin/resinhup-test"
readonly _release_default=latest

GREEN='\033[0;32m'
NC='\033[0m'
RELEASE=$_release_default
REGISTRY_PATHS=$_registry_paths_default

# Help function
function help {
    cat << EOF
Run docker build and push for the supported images.
$0 <OPTION>

Options:
  -h, --help
        Display this help and exit.

  -d <PATH>, --dockerfile <PATH>
        Build and push only this Dockerfile. Otherwise all found will be used.

  -p <PATHS>, --paths <PATHS>
        List of one or more Docker registry paths to push to, quoted, separated
        with spaces. The paths must end with the image name.
        Default: "$_registry_paths_default".

  -r <RELEASE>, --release <RELEASE>
        Release name of the build. This will form the first part of the
        image tag.
        Default: "$_release_default".

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
                echo "[ERROR] \"$1\" argument needs a value."
                exit 1
            fi
            DOCKERFILES=$2
            shift
            ;;
        -p|--paths)
            if [ -z "$2" ]; then
                echo "[ERROR] \"$1\" argument needs a value."
                exit 1
            fi
            REGISTRY_PATHS=$2
            shift
            ;;
        -r|--release)
            if [ -z "$2" ]; then
                echo "[ERROR] \"$1\" argument needs a value."
                exit 1
            fi
            RELEASE=$2
            shift
            ;;
        *)
            echo "[ERROR] Unrecognized option $1."
            exit 1
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
    for path in $REGISTRY_PATHS; do
        printf "${GREEN}Tag and push for $device ...${NC}\n"
        docker build -t $path:$RELEASE-$device -f ../$dockerfile $SCRIPTPATH/..
        docker push $path:$RELEASE-$device
    done
done
