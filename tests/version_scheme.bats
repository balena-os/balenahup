#!/usr/bin/env bats

# Tests determination of the versioning scheme by the version_scheme function,
# which is based on the format of the semver major value.

setup() {
    load 'test_helper'
}

@test "single-digit major rolling version" {
    run_version_scheme 7.4.0

    assert_success
    assert_output "rolling"
}

@test "v2 major as rolling version" {
    run_version_scheme 2.85.0

    assert_success
    assert_output "rolling"
}

@test "major < 2 as unknown" {
    run_version_scheme 1.24.0

    assert_success
    assert_output "unknown"
}

@test "rolling version +rev" {
    run_version_scheme 7.4.0+rev6

    assert_success
    assert_output "rolling"
}

@test "esr version" {
    run_version_scheme 2026.7.0

    assert_success
    assert_output "esr"
}

@test "esr version -draft" {
    run_version_scheme 2023.4.0-1681910697428

    assert_success
    assert_output "esr"
}

@test "nonsense version as unknown" {
    run_version_scheme x.y.z

    assert_success
    assert_output "unknown"
}
