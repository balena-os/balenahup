#!/bin/bash

set -e

echo "[INFO] Running resinhup with default arguments ..."
python3 /app/resinhup.py --config /app/conf/resinhup.conf --debug
exit $?
