# vim: ft=sh

preset() {
    :
}

reset() {
    :
}

tmp_dir=
setup() {
    dbg "[SETUP]"
    tmp_dir=/tmp/bts.test.$$; mkdir -p "$tmp_dir"
    test_file="${tmp_dir}/bts.test_$$.txt"
    test_complex_file="${tmp_dir}/bts.test_$$.Some_Complex_File.20220617180037.txt"
}

teardown() {
    dbg "[TEARDOWN]"
    [[ -n "$tmp_dir" ]] && \rm -rf "$tmp_dir"
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
    assert not true 0
}

assert__assert_not_true_with_num() {
    assert true 11
    assert false -1
    assert not true '-1'
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
    assert not false "11"
    assert not false 1
}

assert__same() {
    assert same "one" "one"
    assert not same "one" "two"
    assert same "abc" <(echo "abc")
    assert same <(echo "abc") <(echo abc)
    assert not same <(echo "abc") <(echo bcd)
    echo 'abc' > "$tmp_dir/some_file"
    assert same "$tmp_dir/some_file" "abc"
    assert same "$tmp_dir/some_file" <(echo "abc")
    assert not same "$tmp_dir/some_file" <(echo "bcd")
    @should_fail assert same "$tmp_dir/some_file" <(echo "bcd")
    @should_fail assert not same "$tmp_dir/some_file" <(echo "abc")
}

assert__same_unordered() {
    assert same~ "one" "one"
    assert not same~ "one" "two"
    assert same~ "abc" <(echo "abc")
    assert same~ <(echo "abc") <(echo abc)
    assert not same~ <(echo "abc") <(echo bcd)
    echo 'abc' > "$tmp_dir/some_file"
    assert same~ "$tmp_dir/some_file" "abc"
    assert same~ "$tmp_dir/some_file" <(echo "abc")
    assert not same~ "$tmp_dir/some_file" <(echo "bcd")
    @should_fail assert same~ "$tmp_dir/some_file" <(echo "bcd")
    @should_fail assert not same~ "$tmp_dir/some_file" <(echo "abc")

    echo -e "abc\ndef\nghi" > "$tmp_dir/some_file"
    echo -e "ghi\nabc\ndef" > "$tmp_dir/some_other_file"
    assert not same "$tmp_dir/some_file" "$tmp_dir/some_other_file"
    assert same~ "$tmp_dir/some_file" "$tmp_dir/some_other_file"
    echo -e "ghi\nabc" > "$tmp_dir/some_other_file"
    assert not same~ "$tmp_dir/some_file" "$tmp_dir/some_other_file"
}

assert_samecol() {
    assert samecol "one" "one"
    assert samecol "one;two" "one;two" 1
    assert samecol "one two" "one two" 2 ' '
    assert samecol "two;three" "two;four" 1
    assert not samecol "two;three" "two;four" 2
    assert samecol "one two" "one four" 1 ' '
    assert not samecol "one;two" "one;four" 1 '-'

    echo -e "one;two;three\none;four;five\none;six;seven" > "$tmp_dir"/cmp1
    echo -e "one;aaa;bbb\none;ccc;ddd\none;eee;fff" > "$tmp_dir"/cmp2

    assert samecol "$tmp_dir"/cmp1 "$tmp_dir"/cmp2 1 ';'
    assert samecol "$tmp_dir"/cmp1 "$tmp_dir"/cmp2 1
    assert samecol "$tmp_dir"/cmp1 "$tmp_dir"/cmp2
}

assert_samecol_unsorted() {
    assert samecol~ "one" "one"
    assert samecol~ "one;two" "one;two" 1
    assert samecol~ "one two" "one two" 2 ' '
    assert samecol~ "two;three" "two;four" 1
    assert not samecol~ "two;three" "two;four" 2
    assert samecol~ "one two" "one four" 1 ' '
    assert not samecol~ "one;two" "one;four" 1 '-'

    echo -e "aaa;zzz\nccc;xxx;\niii;yyy\nbbb;www" > "$tmp_dir/cmp1"
    echo -e "bbb;zzz\naaa;xxx;\nccc;yyy\niii;www" > "$tmp_dir/cmp2"

    assert samecol~ "$tmp_dir"/cmp1 "$tmp_dir"/cmp2 1 ';'
    assert samecol~ "$tmp_dir"/cmp1 "$tmp_dir"/cmp2 1
    assert samecol~ "$tmp_dir"/cmp1 "$tmp_dir"/cmp2
}

assert_assert_exists() {
    assert exists "here I am"
    assert not exists ''
}

load_bts_env() {
    assert same "$test_load" "test_load"
}

assert__assert_file() {
    assert not file "$test_file"
    touch "$test_file"
    assert file "$test_file"
    assert file~ "$tmp_dir/bts.test[^.]+\.txt"
    @should_fail assert file "${test_file}_not_there"
    @should_fail assert file~ "${test_file}.*_not_there"

    touch "$test_complex_file"
    assert file~ "$tmp_dir"'/bts.test_[^.]+.Some_Complex_File.20[2-9][0-9]\(0[1-9]\|1[0-2]\)\(0[1-9]\|[12][0-9]\|3[01]\)[0-5][0-9][0-5][0-9][0-5][0-9]\.txt'
}
