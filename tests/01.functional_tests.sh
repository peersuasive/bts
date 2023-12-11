# vim: ft=sh

test_without_any_preset() {
    return 0
}

test_bts_must_setup_a_variable_reflecting_test_name() {
    assert true '(( bts_must_setup_a_variable_reflecting_test_name ))'
    assert true '(( bts_must_setup_a_variable_reflecting_test_name__test ))'
    @should_fail '(( test_bts_must_setup_a_variable_reflecting_test_name ))'
}
