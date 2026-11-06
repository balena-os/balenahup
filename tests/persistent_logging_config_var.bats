#!/usr/bin/env bats

# Tests persistent_logging_config_var, which cleans up a legacy empty
# RESIN_SUPERVISOR_PERSISTENT_LOGGING value after the OS has been updated.
# It runs after hostapp-update has already switched the device to the new OS,
# so an API failure here must not abort the update.

setup() {
    load 'test_helper'
}

@test "carries on when the config variable query fails" {
    run_persistent_logging_config_var query-fails

    assert_success
    assert_line "done"
    assert_line --partial "[WARNING]"
}

@test "updates config.json when the API PATCH fails" {
    run_persistent_logging_config_var patch-fails

    assert_success
    assert_line "done"
    assert_line --partial "[WARNING]"
    run jq -r '.persistentLogging' "${CONFIGJSON}"
    assert_output "false"
}

@test "patches the variable and updates config.json" {
    run_persistent_logging_config_var patch-succeeds

    assert_success
    assert_line "done"
    refute_line --partial "[WARNING]"
    run jq -r '.persistentLogging' "${CONFIGJSON}"
    assert_output "false"
    run cat "${CURL_LOG}"
    assert_line --index 1 --partial "PATCH https://api.balena-cloud.com/v7/device_config_variable(1234)"
}

@test "leaves a valid value alone" {
    run_persistent_logging_config_var nothing-to-fix

    assert_success
    assert_line "done"
    run jq -r '.persistentLogging' "${CONFIGJSON}"
    assert_output ""
    run cat "${CURL_LOG}"
    refute_line --partial "PATCH"
}
