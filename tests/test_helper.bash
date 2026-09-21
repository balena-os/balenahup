#!/bin/bash

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${TESTS_DIR}")"
FIXTURES_DIR="${TESTS_DIR}/fixtures/releases"
RELEASE_STUBS_DIR="${TESTS_DIR}/stubs/releases"

load "${TESTS_DIR}/test_helper/bats-support/load"
load "${TESTS_DIR}/test_helper/bats-assert/load"

# Helper functions for running tests.
# 
# The 'run_..." functions below run a test. Typically the command looks like below,
# where 'run' is a bats function to run a command.
# https://bats-core.readthedocs.io/en/stable/writing-tests.html#run-test-other-commands
#
# The basic idea for a test function is to run the list of commands passed to
# 'bash -c' as a sort of pseudo-command for the bats 'run' function. The actual
# test is to run the function at the end of the list, which has been sourced from
# the upgrade script.
#
#   run env \
#      bash -c '
#          set -o errexit
#          set -o pipefail
#          BALENAHUP_LIB_ONLY=1
#          # shellcheck disable=SC1090
#          source "$1"
#          version_scheme "$2"
#      ' _ "${REPO_ROOT}/upgrade-2.x.sh" "${version}"
#
# The environment for the function is setup as as needed for a particular test.
# The 'BALENAHUP_LIB_ONLY=1' variable instructs the upgrade script to exit after
# it reads the functions but before it starts the main portion of the script.

#######################################
# Read a global from the script under test, so a test can assert against a
# configured value without restating it.
# Arguments:
#   name: variable to read
# Returns:
#   1 if the variable is unset or empty. Callers must check, since bats' fail
#   would be swallowed by the command substitution this is called from.
#######################################
script_global() {
    local name="$1"
    local value

    value=$(bash -c '
        BALENAHUP_LIB_ONLY=1
        # shellcheck disable=SC1090
        source "$1"
        echo "${!2}"
    ' _ "${REPO_ROOT}/upgrade-2.x.sh" "${name}")

    echo "${value}"
    test -n "${value}"
}

#######################################
# Run get_image_location against a fixture directory.
#
# Arguments:
#   fixture: directory name under tests/fixtures/releases
#   version: target version to query for, defaults to 2.85.0
#######################################
run_get_image_location() {
    local fixture="$1"
    local version="${2:-2.85.0}"

    CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"

    run env \
        FIXTURE_DIR="${FIXTURES_DIR}/${fixture}" \
        CURL_LOG="${CURL_LOG}" \
        PATH="${RELEASE_STUBS_DIR}:${PATH}" \
        bash -c '
            set -o errexit
            set -o pipefail
            BALENAHUP_LIB_ONLY=1
            # shellcheck disable=SC1090
            source "$1"
            CURL=curl
            TMPCRT=/dev/null
            APIKEY=deadbeef
            API_ENDPOINT=https://api.balena-cloud.com
            SLUG=raspberrypi4-64
            get_image_location "$2"
        ' _ "${REPO_ROOT}/upgrade-2.x.sh" "${version}"
}

#######################################
# Run function version_scheme.
#
# Arguments:
#   version: OS version to test
#######################################
run_version_scheme() {
    local version="${1}"

    run env \
        bash -c '
            set -o errexit
            set -o pipefail
            BALENAHUP_LIB_ONLY=1
            # shellcheck disable=SC1090
            source "$1"
            version_scheme "$2"
        ' _ "${REPO_ROOT}/upgrade-2.x.sh" "${version}"
}
