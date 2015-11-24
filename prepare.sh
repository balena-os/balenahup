#!/bin/bash

set -e

echo "Stopping all containers"
rce stop $(rce ps -a -q)

echo "Done"
