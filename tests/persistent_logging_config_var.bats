#!/usr/bin/env bats

# Tests persistent_logging_config_var, which cleans up a legacy empty
# RESIN_SUPERVISOR_PERSISTENT_LOGGING value after the OS has been updated, in
# the API and in config.json. The config.json fix must not depend on the API.
# Any failure is reported with its return status, leaving config.json as it
# was if the config.json fix failed, so that its caller decides what a failure
# means.

setup() {
    load 'test_helper'
}

@test "fails but still fixes config.json when the config variable query fails" {
    run_persistent_logging_config_var query-fails

    assert_success
    assert_line "returned 1"
    run jq -r '.persistentLogging' "${CONFIGJSON}"
    assert_output "false"
}

@test "fails but still fixes config.json when the API PATCH fails" {
    run_persistent_logging_config_var patch-fails

    assert_success
    assert_line "returned 1"
    run jq -r '.persistentLogging' "${CONFIGJSON}"
    assert_output "false"
}

@test "patches the variable and updates config.json" {
    run_persistent_logging_config_var patch-succeeds

    assert_success
    assert_line "returned 0"
    refute_line --partial "[WARNING]"
    run jq -r '.persistentLogging' "${CONFIGJSON}"
    assert_output "false"
    run cat "${CURL_LOG}"
    assert_line --index 1 --partial "PATCH https://api.balena-cloud.com/v7/device_config_variable(1234)"
    run ls "${BATS_TEST_TMPDIR}/boot"
    assert_output "config.json"
}

@test "fixes config.json when the API variable is already valid" {
    run_persistent_logging_config_var nothing-to-fix

    assert_success
    assert_line "returned 0"
    run jq -r '.persistentLogging' "${CONFIGJSON}"
    assert_output "false"
    run cat "${CURL_LOG}"
    refute_line --partial "PATCH"
}

@test "leaves valid values alone" {
    mkdir -p "${BATS_TEST_TMPDIR}/boot"
    echo '{"uuid":"0123","persistentLogging":"false"}' > "${BATS_TEST_TMPDIR}/boot/config.json"

    run_persistent_logging_config_var nothing-to-fix

    assert_success
    assert_line "returned 0"
    run cat "${CONFIGJSON}"
    assert_output '{"uuid":"0123","persistentLogging":"false"}'
    run cat "${CURL_LOG}"
    refute_line --partial "PATCH"
}

@test "fails and leaves an unparsable config.json untouched" {
    mkdir -p "${BATS_TEST_TMPDIR}/boot"
    printf '{"uuid": "0123", "persistentLogging": ""' > "${BATS_TEST_TMPDIR}/boot/config.json"

    run_persistent_logging_config_var patch-succeeds

    assert_success
    assert_line "returned 1"
    run cat "${CONFIGJSON}"
    assert_output '{"uuid": "0123", "persistentLogging": ""'
    run ls "${BATS_TEST_TMPDIR}/boot"
    assert_output "config.json"
}

@test "fails and leaves config.json in place when it cannot be replaced" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "root can write to a read-only directory"
    fi
    mkdir -p "${BATS_TEST_TMPDIR}/boot"
    echo '{"persistentLogging":""}' > "${BATS_TEST_TMPDIR}/boot/config.json"
    chmod a-w "${BATS_TEST_TMPDIR}/boot"

    run_persistent_logging_config_var patch-succeeds
    chmod u+w "${BATS_TEST_TMPDIR}/boot"

    assert_success
    assert_line "returned 1"
    run cat "${CONFIGJSON}"
    assert_output '{"persistentLogging":""}'
    run ls "${BATS_TEST_TMPDIR}/boot"
    assert_output "config.json"
}
