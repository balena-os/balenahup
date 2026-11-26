#!/usr/bin/env bats

# Tests that upgrade-takeover.sh can be sourced for its functions alone, which
# the takeover tests rely on.

setup() {
    load 'test_helper'
}

@test "lib mode defines the functions without running the update" {
    run_takeover_function declare -F download_target_image

    assert_success
    assert_output "download_target_image
done"
}
