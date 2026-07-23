#!/bin/bash

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${TESTS_DIR}")"
FIXTURES_DIR="${TESTS_DIR}/fixtures/releases"
STUBS_DIR="${TESTS_DIR}/stubs"

load "${TESTS_DIR}/test_helper/bats-support/load"
load "${TESTS_DIR}/test_helper/bats-assert/load"

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
        PATH="${STUBS_DIR}:${PATH}" \
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
