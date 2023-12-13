# vim: ft=sh

#@bts_cont --unit-tests

test_without_any_preset() {
    return 0
}

test_bts_must_setup_a_variable_reflecting_test_name() {
    assert true '(( bts_must_setup_a_variable_reflecting_test_name ))'
    assert true '(( bts_must_setup_a_variable_reflecting_test_name__test ))'
    @should_fail '(( test_bts_must_setup_a_variable_reflecting_test_name ))'
}

test_bts_must_set_current_test_in_var____current___test() {
    assert true [[ "\$__bts_current_test" == "test_bts_must_set_current_test_in_var____current___test" ]]
}

## passing empty parameters when calling a function must be kept
__arguments_must_be_kept() {
    local one="$1"
    local two="${2:-}"
    local three="$3"

    local exp_one="${expected_one}"
    local exp_three="${expected_three}"

    [[ -z "${two:-}" ]]
    [[ "$exp_one" == "$one" ]]
    [[ "$exp_three" == "$three" ]]
}
empty_arguments_must_be_kept() {
    local expected_one="first argument"
    @export_var expected_one
    local expected_three="third argument"
    @export_var expected_three
    assert ok __arguments_must_be_kept "$expected_one" "" "$expected_three"
}
empty_arguments_must_be_kept_with_quoted_arguments() {
    local expected_one='first argument'
    @export_var expected_one
    local expected_three='third argument "with more details to come"'
    @export_var expected_three
    assert ok __arguments_must_be_kept "$expected_one" "" "$expected_three"
}
empty_arguments_must_be_kept_with_special_chars() {
    local expected_one='first argument'
    @export_var expected_one
    local expected_three='third argument (with more details to come)'
    @export_var expected_three
    assert ok __arguments_must_be_kept "$expected_one" "" "$expected_three"
}

capture_logs_should_get_logs() {
    local rnd="$RANDOM"
    @capture_logs echo "HELO $rnd"
    assert log "HELO $rnd"
}

capture_logs_should_get_err_logs() {
    local rnd="$RANDOM"
    local rnd2="$RANDOM"
    @capture_logs @should_fail '( echo "OLEH $rnd" >&2; exit 1; )'
    assert err "OLEH $rnd"
    @capture_logs '( echo "HELO$rnd2" >&2; exit 1; )' || true
    assert err "HELO$rnd2"
}

capture_logs_should_get_warn_logs() {
    local rnd="$RANDOM"
    @capture_logs echo "OLEH $rnd" >&1
    assert warn "OLEH $rnd"

    @capture_logs echo "HELO $rnd" >&2
    assert warn "HELO $rnd"
}

assert_log_should_succeed() {
    local rnd="$RANDOM"
    local rnd2="$RANDOM"
    echo "OLEH $rnd"
    assert log "OLEH $rnd"
    echo "HELO$rnd2"
    assert log "HELO$rnd2"
}
assert_log_err_should_succeed() {
    local rnd="$RANDOM"
    local rnd2="$RANDOM"
    ( echo "OLEH $rnd" >&2; exit 1; ) || true
    assert err "OLEH $rnd"
    ( echo "HELO$rnd2" >&2; exit 1; ) || true
    assert err "HELO$rnd2"
}
assert_log_warn_should_succeed() {
    local rnd="$RANDOM"
    local rnd2="$RANDOM"
    ( echo "OLEH $rnd" >&2; exit 1; ) || true
    assert warn "OLEH $rnd"
    echo "HELO$rnd2"
    assert warn "HELO$rnd2"
}
