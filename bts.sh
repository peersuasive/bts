#!/usr/bin/env bash

set -o pipefail

usage() {
    cat <<EOU
Usage: ${0##*/} [-h] [OPTIONS] [test...]

Usage notes:
    Tests are expected to be found in folder 'tests/',
    named as '[NN].<test>.sh'; ex.: tests/00.bts_tests.sh.

    Results are stored in 'results/[TEST CLASS]/[TEST NAME].log'
    Tests classes are to be stored in 'tests/[0-9]*.test_name.sh'
    Tests starting with underscore (_) or arobase (@) are ignored.
    Tests are executed in order.

Options:
    -h|--help               show this message and exit
    -v|--verbose            show output in case of failure only (default)
    -vv|--very-verbose      always show output
    -q|--quiet              don't show output, even in case of failure
    -qq|--very-quiet
    -s|--silent             don't show any output at all
    -l|--list|--list-tests  list available test without executing

Utils (functions):
    setup    run before each test
    teardown run after each test
    preset   run before first test
    reset    run after last test
    fail     exit test immediatly with a failure (FAIL) message
    ok       exit test immediatly with a success (OK) message
    todo     exit test immediatly with a TODO message; this is accounted as a failure but notified as an unimplemented test also
    assert [true|false|equals|same] <expression>
        true    assert evaluation is true
        false   assert evaluation if false
        equals  assert left string equals expected right string
        same    assert left string or file contents equals expected right string or file contents
    @should_fail <expression>
                assert next evaluation fails as expected
Debug/trace:
    trace    display message in output (logged)
    dbg      display a dbg message in output (logged)
EOU
}

## ----------------------- lib
declare RST BLINK INV BLUE RED YELLOW MAGENTA WHITE CYAN
_set_colors() {
    declare -gr BOLD='\e[1m'
    declare -gr RST='\e[0m'
    declare -gr BLINK='\e[5m'
    declare -gr INV='\e[7m'
    declare -gr BLUE='\e[34m'
    declare -gr RED='\e[31m'
    declare -gr YELLOW='\e[33m'
    declare -gr MAGENTA='\e[35m'
    declare -gr WHITE='\e[97m'
    declare -gr CYAN='\e[36m'
}
OK=OK
FAILED=FAILED
FATAL=FATAL
TODO=TODO
MSG_STATUS=

r_ok=0
r_fail=1
r_fatal=2
r_warn=3
r_todo=4

echo_c() {
    local s=$1; shift
    case "$s" in
        FAILED|FATAL|SYNTAX) echo -e "${BOLD}${RED}${BLINK}$@${RST}";;
        WARNING|WARN) echo -e "${RED}${BLINK}$@${RST}";;
        OK) echo -e "${BOLD}${BLUE}$@${RST}";;
    esac
}

fail() {
    [[ -n "$1" ]] && echo "[$FAILED] $@"
    return $r_fail
}
ok() {
    [[ -n "$1" ]] && echo "[$OK] $@"
    return $r_ok
}
fatal() {
    [[ -n "$1" ]] && echo "[$FATAL] $@" >&2
    return $r_fatal
}
todo() {
    echo -ne "${YELLOW}[$TODO]${@+ ${BOLD}${CYAN}$@}${RST}" >&2
    exit $r_todo
}

dbg() {
    echo -e "[DBG] $@" >&2
}
trace() {
    echo "$@" >&2
}

export SHOULD=0
export SHOULD_FAIL=0
@should_fail() {
    local r
    SHOULD=1
    SHOULD_FAIL=1
    ( trap - ERR; (! eval "$@") ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
    fail
}

assert() {
    local NOT=0
    [[ "$1" == NOT || "$1" == not ]] && NOT=1 && shift
    local is_not=$( ((NOT)) && echo 'NOT ' )
    local a="$1"; shift
    local res1 res2 r
    case "${a^^}" in
        TRUE|FALSE|EQUALS|SAME|EXISTS) a=${a^^};;
        *) echo "unknown assertion '$a' (${f}:${FUNCNAME[1]}:${BASH_LINENO[0]})"; return $r_fail;;
    esac
    set -- "$@"
    [[ -z "${@+z}" ]] && echo_c SYNTAX "Missing evaluation!" && exit 1
    local cmp="$1"
    local exp="$2"
    local cmp_f exp_f
    case $a in
        TRUE|FALSE)
            [[ -n "$cmp" && ! "$cmp" =~ ^[0]+$ && ! "$cmp" =~ ^[\t\ ]*[Ff][Aa][Ll][Ss][Ee][\t\ ]*$ ]] && {
                [[ "$cmp" =~ ^[\t\ ]*[Tt][Rr][Uu][Ee][\t\ ]*$ || "$cmp" == "1" ]] && r=0 || {
                    (eval "$@";) && r=0
                }
            } || r=1
            [[ "$a" == FALSE ]] && r=$((!r));;
        EQUALS) [[ "$cmp" == "$exp" ]] && r=0 || r=1;;
        SAME)
            [[ -r "$exp" ]] && exp_f="$exp"||:; [[ -r "$cmp" ]] && cmp_f="$cmp"||:;
            diff -q ${cmp_f:-<(echo "$1")} ${exp_f:-<(echo "$2")} >/dev/null 2>/dev/null && r=0 || r=1;;
    esac
    local old_r=$r
    ((NOT)) && r=$((!r))
    ((r)) && {
        local line func
        ((SHOULD)) && {
            func=${FUNCNAME[2]}
            line=${BASH_LINENO[1]}
        } || {
            func=${FUNCNAME[1]}
            line=${BASH_LINENO[0]}
        }
        ((SHOULD_FAIL && !SHOW_OUTPUT)) && return $r
        ((SHOULD_FAIL)) && failed_expected=' (expected)'
        echo "assertion failed${failed_expected}: ${f}:${func}:${line}:"
        
        echo " assert ${is_not}${a} $@"
        [[ "$a" == SAME ]] && {
            echo -e "expected${exp_f:+ (from '$exp_f')}:\n----------\n$(cat ${exp_f:-<(echo "$exp")})\n----------"
            echo -e "got${cmp_f:+ (from '$cmp_f')}:\n----------\n$(cat ${cmp_f:-<(echo $cmp)})\n----------"
        }
        return $r
    }
    return 0
}

## ------ params

LIST_ONLY=0
INTERACTIVE=0
SHOW_OUTPUT=0
SHOW_FAILED=1
NO_COLORS=0
## no tests found
! [[ -d tests ]] && exit 0

oldIFS=$IFS
home="$( dirname "$(readlink -f "$0")" )"
here="$(readlink -f "$PWD")"
results_base="$here/results"

## ------ functions
declare -a tests=()
declare -A tests_i=()
declare -A tests_ext=()
_get_test() {
    local t="${1:?Missing tests class}"
    tests=()
    tests_i=()
    tests_ext=()
    ## evaluate script first
    ( source "$t" 1>/dev/null ) || return 1
    local xxx
    xxx=$(cat <<EOS|bash
    shopt -s extdebug
    source "$t" 1>/dev/null || exit 1
    declare -A ext
    for e in \$(
        for x in \$(declare -F|awk -F' ' '{print \$NF}'|grep -Ev '^[\t ]*(_|@)'); do
            case \$x in
                setup|teardown|preset|reset)
                    echo "00:\$x";;
                *) l=\$(declare -F \$x|awk '{print \$2}')
                   echo \$l:\$x
            esac
        done | sort -h); do
        [[ "\$e" =~ ^00: ]] && {
            ee="\${e##*:}"
            echo "tests_ext[\${ee##*_}]=\"\$ee\";"
        } || echo "tests+=( \${e##*:} );"
    done | grep -E '^(tests\+=|tests_ext\[)' # discard user's echo
EOS
) || return 1 ## end of eval
    eval "$xxx"
    !((${#tests[@]})) && echo "Warning: no tests found in '$t'."
    for t in ${tests[@]}; do tests_i["$t"]="$t"; done
    return 0
}

_run_tests() {
    local prev_failed=0
    local f="${1:?Missing test class}"
    local l_t="$2"
    local l_tests=( "${l_t:-${tests[@]}}" )
    local setup="${tests_ext[setup]}"
    local teardown="${tests_ext[teardown]}"
    local preset="${tests_ext[preset]}"
    local reset="${tests_ext[reset]}"

    failed=0
    unimplemented=0
    total=${#l_tests[@]}; local s; ((total>1)) && s='s'

    echo "Executing $total test$s"
    echo
    local n nn
    local _preset_executed=0
    local _end=$(( ${#l_tests[@]} ))
    local _cur=0
    local _is_last=0
    for t in ${l_tests[@]}; do
        ((++cur >= _end)) && _is_last=1
        ((++n)); nn=$(printf "%02d" "$n")
        local ts=${t##*test_}; ts=${ts//__/: }; ts=${ts//_/ }
        local log_file="${results}/${nn}.${t}.log"
        local log_file_err="${results}/${nn}.${t}.err.log"
        ((SHOW_OUTPUT && n>1)) || (( SHOW_FAILED && prev_failed)) && echo
        echo -en "[$n/${total}] ${BOLD}${WHITE}${ts}${RST}"
        (
            exec 8>&1
            exec 9>&2
            exec 1>>$log_file
            exec 2>>$log_file

            echo "--- [$t] ----"

            set -o pipefail
            set -eE
            set -o functrace
            _trap_exit() {
                local retval=$?
                \rm -f "$tmp_sh"
                exit $retval
            }
            trap '_trap_exit' EXIT
            trap '_trap_exit' SIGINT
            trap '_trap_exit' SIGTERM
            trap '_trap_exit' KILL

            _trap_err() {
                local retval=$?

                local lineno="${BASH_LINENO[1]}"
                local line fline func
                ((SHOULD)) && {
                    dbg "IS A SHOULD"
                    line=${BASH_LINENO[1]}
                    func="${FUNCNAME[2]}"
                } || {
                    dbg "IS NOT A SHOULD"
                    line=${BASH_LINENO[0]}
                    func="${FUNCNAME[1]}"
                }
                fline="$line"
                [[ "$func" != "$t" && ! "$func" =~ \@should_ ]] && {
                    fline="[UNDEF]"
                    func="$t"
                }
                local err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n')
                
                echo "Failed at ${f}:${func}:${fline} -> ${err_line:-$BASH_COMMAND} (--> [${FUNCNAME[@]}, ${BASH_LINENO[@]}])"
                dbg "TRAP TO RETURN $retval"
                return $retval
            }
            trap '_trap_err' ERR
            
            command_not_found_handle() {
                local line=${BASH_LINENO[0]}
                local err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n')
                echo "FATAL: command not found: ${f##*/}:${FUNCNAME[1]}:${BASH_LINENO[0]}: $err_line"
                exit $r_fatal
            }

            tmp_sh=$(mktemp -uq -p /tmp -t nris.XXXXXXXXXX)
            cat "$f" > "$tmp_sh"
            this="$(basename $( readlink -f "$f" ))"; this="${this%.sh}"
            sed -ri 's;%\{this\};'"${this}"';g;s;%\{this_test\};'"${t}"';g' "$tmp_sh"
            source "$tmp_sh"
            \rm -f "$tmp_sh"
            ((!_preset_executed)) && {
                _preset_executed=1
                [[ -n "$preset" ]] && { 
                    local pre_log
                    pre_log=$( $preset ) || exit $r_fatal
                    echo "$pre_log" | grep -q 'command not found' && echo "$pre_log" && exit $r_fatal
                }
            }

            [[ -n "$setup" ]] && { $setup || exit $r_fatal2; }

            $t; rr=$?

            [[ -n "$teardown" ]] && { 
                $teardown || { echo "WARN: failed to execute '$teardown'!"; ((!rr)) && rr=$r_warn; }
            }
            ((_is_last)) && {
                [[ -n "$reset" ]] && {
                    $reset || { echo "WARN: failed to execute '$reset'!"; ((!rr)) && rr=$r_warn; }
                }
            }
            echo "--- [$( ((rr)) && echo $FAILED || echo $OK)]: $t --------"
            exec 1>&8
            exec 2>&9
            exec 7>&-
            exit $rr
        ); r=$?
        ((r)) && prev_failed=1 || prev_failed=0

        _no_forced_log=0
        case $r in
            $r_ok) echo_c OK " -> [$OK]"
                ;;

            $r_todo) echo_c FAILED " -> [$TODO]"
                _no_forced_log=1
                prev_failed=0
                ((++failed))
                ((++unimplemented))
                ;;
            $r_fail) echo_c FAILED " -> [$FAILED]"
                ((++failed))
                ;;

            $r_fatal|$r_fatal2) echo_c FATAL " [FATAL] Failed to execute $( ((r==r_fatal)) && echo 'preset' || echo 'setup')"
                cat "$log_file"
                return 2
                ;;

            $r_warn) echo_c WARN " [WARNING] Failed to execute some environmental method"
                ;;

            *) echo " -> [UNK STATE:$r]"
                ;;
        esac
        ((r==$r_warn || r==$r_fatal || SHOW_OUTPUT)) && cat "$log_file" || {
            ((r && SHOW_FAILED && !_no_forced_log )) && cat "$log_file"
        }
    done
}

## ----- main

run() {
    local f
    \rm -rf "$results_base"
    mkdir -p "$results_base"
    local results
    local total_run=0
    local f
    ## load local env
    if [[ -f 'bts.env' ]]; then
        eval $(while read l; do
            [[ "$l" =~ ^# || ! "$l" =~ = ]] && continue
            ! [[ "$l" =~ ^[\t\ ]*export[\t\ ]+ ]] && l="export $l"
            echo $l
        done <bts.env)
    fi
    for f in ${test_list}; do
        local ff="$f"
        local t=''
        [[ "$f" =~ ^([^:]+):(.+)$ ]] && {
            ff="${BASH_REMATCH[1]}"
            t="${BASH_REMATCH[2]}"
        }
        ff="$(readlink -f "$ff")"; ! [[ -f "$ff" ]] && echo -e "${INV}[WARNING] Can't find test class '$ff'!${RST}" && continue
        ! _get_test "$ff" && echo "Error: Failed to parse test class '$ff'" && continue
        [[ -n "$t" && -z "${tests_i["$t"]}" ]] && echo -e "${INV}[WARNING] Can't find test '$t' in class '$ff'!${RST}" && continue

        declare int_tests=()
        ((LIST_ONLY)) && {
            local i=0
            echo -e "${INV}Test class ${BOLD}${CYAN}$f${RST}"
            for k in ${!tests_i[@]}; do
                local kk="$k"
                #local kk=${k//__/: }; kk=${kk//_/ }
                int_tests+=( "$k" )
                printf "${BOLD}${BLUE}[%02d] ${BOLD}${CYAN}%s${RST}\n" $((++i)) "$kk"
            done
            continue
        }

        #((total_run++)) && echo
        local total=0
        local failed=0
        local fr=${ff##*/}
        results="$results_base/${fr%.*}"; mkdir -p "$results"
        echo -e "${INV}Running test class ${BOLD}${CYAN}$f${RST}"
        _run_tests "$ff" "$t"
        echo
        echo -e "-> [$((total-failed))/$total] ($failed failure$(((failed>1)) && echo s)$(((unimplemented)) && echo ", $unimplemented being unimplemented test$(((unimplemented>1))&& echo s)"))"
    done
}

ARGS=()
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0;;
        -vv|--very-verbose) SHOW_OUTPUT=1;;
        -v|--verbose) SHOW_FAILED=1;;
        -C|--no-color) NO_COLORS=1;;
        -c|--color) NO_COLORS=0;;
        -q|--quiet) SHOW_FAILED=0;;
        -qq|--very-quiet|-s|--silent) SHOW_FAILED=0; SHOW_OUTPUT=0;;
        -l|--list|--list-tests) LIST_ONLY=1;;
        #-i|--interactive) LIST_ONLY=1; INTERACTIVE=1;;
        *) ARGS+=( "$1" );;
    esac
    shift
done
!((NO_COLORS)) && _set_colors
set -- "${ARGS[@]}"

test_list="${@:-$here/tests/[0-9]*.sh}"
run
