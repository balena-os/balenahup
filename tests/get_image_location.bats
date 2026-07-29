#!/usr/bin/env bats

# Covers the release query in get_image_location, which must pick the image
# built by the "hostapp" service out of a host OS release that may also bundle
# extension images.
#

setup() {
    load 'test_helper'
}

@test "picks the only image when the release bundles a single hostapp" {
    run_get_image_location single-hostapp

    assert_success
    assert_output "registry2.balena-staging.com/v2/14d96ac3064492f64f75a7a6d53e004f@sha256:3a7b912f92407133ec79967ed712789e4b41bf9bf1adcf65069f06e13da6c823"
}

@test "picks the hostapp image when an extension comes first" {
    run_get_image_location hostapp-not-first

    assert_success
    assert_output "registry2.balena-staging.com/v2/bc8c3a32e170ff8c9301686b81db964a@sha256:442c6b3c2959f5c8a4a5156488d68322b7c0a261956687489c4c5935af51b59e"
}

@test "picks the hostapp image out of several extensions" {
    run_get_image_location hostapp-with-extensions

    assert_success
    assert_output "registry2.balena-staging.com/v2/d1cc383a5248e92f59d3335ad9875664@sha256:70d7e47608dc490ddfb3b8fd3193be88805b86a409a00a74d2f7c398a9df2ffe"
}

@test "picks the only image of a legacy release built by the main service" {
    run_get_image_location legacy-main-service

    assert_success
    assert_output "registry2.balena-staging.com/v2/c2c95046a3b3920cbbd099d8da0a626d@sha256:4a7993657cde2baf56b95eeb31f6c722568e1b0d8af06d1f0c45bb6bd139bb57"
}

@test "picks the fallback image when the primary is empty for an old esr release" {
    run_get_image_location legacy-main-fallback

    assert_success
    assert_output "registry2.balena-cloud.com/v2/bf8379ff26618556d94ce799a4917b40@sha256:56b57e62d4f7f8bda326f199ebca216d27d0decbc3d306178d53d5e5cb22ca90"
}

@test "returns nothing when the only image is an extension" {
    run_get_image_location single-extension-only

    assert_success
    assert_output ""
}

@test "returns nothing when the service expansion is empty" {
    run_get_image_location empty-service-array

    assert_success
    assert_output ""
}

@test "falls back to the release_tag query when no image is a hostapp" {
    run_get_image_location no-hostapp-service

    assert_success
    assert_output "registry2.balena-staging.com/v2/14d96ac3064492f64f75a7a6d53e004f@sha256:3a7b912f92407133ec79967ed712789e4b41bf9bf1adcf65069f06e13da6c823"
}

@test "returns nothing when no release matches the version" {
    run_get_image_location no-match

    assert_success
    assert_output ""
}

@test "returns nothing when several releases match the version" {
    run_get_image_location multiple-releases

    assert_success
    assert_output ""
}

@test "returns nothing when a release carries no images" {
    run_get_image_location missing-contains-image

    assert_success
    assert_output ""
}

# The API leaves a null content hasd
# on releases whose build failed (like raspberrypi5 7.4.0+rev13) in this fixture.

# A failed release still matches and the selector returns "<location>@null".
# That is not a valid digest reference, so the update gets as far as the image
# pull before failing, and reports "all hostapp-update attempts have failed"
# rather than saying the release never built.
#
# The test pins that behaviour so the effect of a fix is visible.
@test "emits an unusable reference when the content hash is null" {
    run_get_image_location null-content-hash

    assert_success
    assert_output "registry2.balena-staging.com/v2/fd2197f0e5b9f6e702ff09e9c9be3ed7@null"
}

@test "queries the configured release API version, falling back to release_tag" {
    local api_version
    api_version=$(script_global RELEASE_API_VERSION) \
        || fail "RELEASE_API_VERSION is unset, so the queries would request //release"

    run_get_image_location no-hostapp-service
    assert_success

    run cat "${CURL_LOG}"
    assert_line --index 0 --partial "/${api_version}/release?"
    assert_line --index 1 --partial "/${api_version}/release?"
    refute_line --index 0 --partial "release_tag"
    assert_line --index 1 --partial "release_tag"
}

@test "aborts when the API query fails" {
    run_get_image_location query-failure

    assert_failure
    assert_output ""
}

@test "strips the variant tag from the queried version" {
    run_get_image_location single-hostapp 2.85.0.prod

    assert_success
    assert_output "registry2.balena-staging.com/v2/14d96ac3064492f64f75a7a6d53e004f@sha256:3a7b912f92407133ec79967ed712789e4b41bf9bf1adcf65069f06e13da6c823"
}
