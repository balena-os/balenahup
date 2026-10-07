#!/usr/bin/env bats

# Tests determination of the current supervisor version and scheduled supervisor
# version in the _fetch_supervisor_version function.

setup() {
    load 'test_helper'
}

@test "no scheduled version" {
    run_fetch_supervisor_version no-scheduled-version

    assert_success
    assert_output "12.2.11 12.2.11"
}

@test "has scheduled version" {
    run_fetch_supervisor_version has-scheduled-version

    assert_success
    assert_output "12.2.11 18.2.2"
}
