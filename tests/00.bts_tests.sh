# vim: ft=sh

preset() {
    :
}

reset() {
    :
}
setup() {
    dbg "[SETUP]"
}

teardown() {
    dbg "[TEARDOWN]"
}

_disabled_test() {
    echo "not really disabled..."
    echo "not really disabled either..."
    assert equals 1 1
    #fail "forced failure -> TODO"
    assert "false" 'true'
    [[ -n "$truc" ]] && return 1
    return 0
}

should_fail() {
    @should_fail 'return 1'
    ( trap - ERR; ! @should_fail 'return 0' )
    ( trap - ERR; ! @should_fail @should_fail 'return 1' )
    @should_fail @should_fail 'return 0'
    @should_fail @should_fail @should_fail 'return 1'
    return 0
}

assert__assert_true() {
    @should_fail assert 'true' 'false'
    assert 'true' 'true'
    assert 'true' 'return 0'
    assert true [[ 1 == 1 ]]
    @should_fail assert true [[ 1 == 2 ]]
    assert true [[ 1 == 1 ]]
    assert true TRUE
    assert true true
    assert true tRuE
    assert not true FALSE
    assert not true FaLsE
    assert true 1
    assert not true 11
    assert not true 0
}

assert__assert_false() {
    @should_fail assert 'false' 'true'
    assert false false
    assert false return 1
    assert false [[ 1 == 2 ]]
    @should_fail assert false [[ 1 == 1 ]]
    assert false [[ 1 == 0 ]]
    assert false FALSE
    assert false false
    assert false FaLsE
    assert not false TRUE
    assert not false TrUe
    assert false 0
    assert false "11"
    assert not false 1
}

assert__same() {
    assert same "one" "one"
    assert not same "one" "two"
    assert same <(echo "abc") "abc"
    assert same <(echo "abc") <(echo abc)
    assert not same <(echo "abc") <(echo bcd)
    echo 'abc' > "/tmp/some_file"
    assert same "/tmp/some_file" "abc"
    assert same "/tmp/some_file" <(echo "abc")
    assert not same "/tmp/some_file" <(echo "bcd")
    @should_fail assert same "/tmp/some_file" <(echo "bcd")
    @should_fail assert not same "/tmp/some_file" <(echo "abc")
}
