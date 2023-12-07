# vim: ft=sh:ts=2:sts=2:sw=2:expandtab

@bts_cont

setup() {
  echo "XXXXXXXXX"
}

test_container_launch() {
    lsb_release -a | grep 'Distributor ID'| awk -F':' '{ print $2 }' 1>/dev/null
}
