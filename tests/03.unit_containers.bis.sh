#!/usr/bin/env bash

#@bts_unit_cont Dockerfile.with_pandoc
@bts_unit_cont Dockerfile.with_pandoc

test_pandoc_command_should_be_available() {
    assert file /run/.containerenv || assert file /.dockerenv
    assert true 'command -V pandoc'
}
