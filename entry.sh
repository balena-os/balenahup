#!/bin/sh

# Optional wrapper to execute a host OS update. This wrapper provides a fixed
# entry point for Supervisor managed OS updates, allowing us to change the working
# script as the host update process evolves without altering how the Supervisor
# starts the update.
#
# Runs the working script in the current process with the arguments provided to
# this script.
exec ./upgrade-2.x.sh "$@"
