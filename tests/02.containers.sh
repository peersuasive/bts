# vim: ft=sh:ts=2:sts=2:sw=2:expandtab

## test with one container for all

@bts_cont

test_container_launch() {
    lsb_release -a | grep 'Distributor ID'| awk -F':' '{ print $2 }' 1>/dev/null
    ## unit tests are usually running with docker (but might be podman, though)
    assert file /.dockerenv || assert file /run/.containerenv
}

## both these tests are linked (note: must be ordered, because typeset -F is alphanum-ordering!)
test_start_anew_after_each_test_01__no_expectation() {
    touch /tmp/dont_be_there.txt
}
test_start_anew_after_each_test_02__validation_failure() {
    @should_fail assert NOT file /tmp/dont_be_there.txt
}
