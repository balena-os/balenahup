#!/bin/bash

set -e

echo "Stopping all containers"
rce stop $(rce ps -a -q)

echo "Stop cron jobs"
/etc/init.d/crond stop

echo "Done"
