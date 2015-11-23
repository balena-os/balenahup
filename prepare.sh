#!/bin/bash

set -e

echo "Stopping all containers"
rce stop $(rce ps -a -q)

echo "Building the image"
rce build -t resinhup .

echo "Run container using:"
echo "rce run -ti --privileged --rm --net=host --volume /:/host resinhup /bin/bash"

echo "Done"
