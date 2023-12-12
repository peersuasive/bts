# vim: ft=sh:ts=2:sts=2:sw=2:expandtab

## test with one container for all

@bts_unit_cont

test_container_launch() {
    lsb_release -a | grep 'Distributor ID'| awk -F':' '{ print $2 }' 1>/dev/null
    ## unit tests are running with podman but this might change in the future
    assert file /run/.containerenv || assert file /.dockerenv
}

## both these tests are linked (note: must be ordered, because typeset -F is alphanum-ordering!)
test_start_anew_after_each_test_01__no_expectation() {
    touch /tmp/dont_be_there.txt
}
test_start_anew_after_each_test_02__validation() {
    assert NOT file /tmp/dont_be_there.txt
}
