#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m'

# Get the absolute script location
pushd `dirname $0` > /dev/null 2>&1
SCRIPTPATH=`pwd`
popd > /dev/null 2>&1

for dockerfile in `ls $SCRIPTPATH/../Dockerfile.*`; do
    dockerfile=$(basename $dockerfile)
    device=$(echo $dockerfile | cut --delimiter '.' -f2)
    if [ -z "$device" ]; then
        echo "ERROR: Can't detect device name for $dockerfile"
        exit 1
    fi
    printf "${GREEN}Running build for $device using $dockerfile ...${NC}\n"
    docker build -t resinhup-$device -f ../$dockerfile $SCRIPTPATH/..
    printf "${GREEN}Tag an push for $device ...${NC}\n"
    docker tag -f resinhup-$device registry.resinstaging.io/resinhup/resinhup-$device
    docker push registry.resinstaging.io/resinhup/resinhup-$device
done
