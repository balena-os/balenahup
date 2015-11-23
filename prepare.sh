#!/bin/bash

set -e

echo "Stopping resin-supervisor"
systemctl stop resin-supervisor

echo "Building the image"
rce build -t resinhup .

echo "Done"
