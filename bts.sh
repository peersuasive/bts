#!/usr/bin/env bash

set -o pipefail
set -u

DEBUG=${DEBUG:-0}
DEBUG_BTS=${DEBUG_BTS:-0}

usage() {
    cat <<EOU
Usage: ${0##*/} [-h] [OPTIONS] [test...]

Usage notes:
    Tests are expected to be found in folder 'tests/' (see '-t' option),
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
    -t|--tests-dir <dir>    look for tests in 'dir' instead of 'tests'
    -D|--DEBUG              debug BTS
    -dd|--extra-debug       enable extra dbg traces (typically, turns 'set -x' on)
    -d|--debug              enable dbg traces
    

Utils (functions):
    setup    run before each test
    teardown run after each test
    preset   run before first test
    reset    run after last test
    fail     exit test immediatly with a failure (FAIL) message
    ok       exit test immediatly with a success (OK) message
    todo     exit test immediatly with a TODO message; this is accounted as a failure but notified as an unimplemented test also
    assert [true|false|equals|same] <expression>
        true     assert evaluation is true
        false    assert evaluation if false
        equals   assert left string equals expected right string
        same     assert left string or file contents equals expected right string or file contents
        same~    assert left string or unordered file contents equals expected right string or unordered file contents
        samecol  compare same column from two files; column number and separator can be passed after files (default: column 1, comma (;) as separator)
        samecol~ compare same column from two unordered files; column number and separator can be passed after files (default: column 1, comma (;) as separator)
        exists   assert contents exist
    @should_fail <expression>
                assert next evaluation fails as expected
Debug/trace:
    trace    display message in output (logged)
    dbg      display a dbg message in output (logged)
EOU
}

exp_vars=()
exp_cmds=()

## ----------------------- lib
declare RST BLINK INV BLUE RED GREEN YELLOW MAGENTA WHITE CYAN
diff_=$(which diff) || { fatal "Can't find 'diff' command!"; exit 1; }
diff() {
    $diff_ "$@"
}
_set_colors() {
    declare -gr BOLD='\033[1m'
    declare -gr RST='\033[0m'
    declare -gr BLINK='\033[5m'
    declare -gr INV='\033[7m'
    declare -gr UND='\033[4m'
    declare -gr BLACK='\033[30m'
    declare -gr RED='\033[31m'
    declare -gr GREEN='\033[32m'
    declare -gr YELLOW='\033[33m'
    declare -gr BLUE='\033[34m'
    declare -gr MAGENTA='\033[35m'
    declare -gr CYAN='\033[36m'
    declare -gr GRAY='\033[37m'
    declare -gr WHITE='\033[97m'
    declare -gr BLACKB='\033[0;40m'
    declare -gr REDB='\033[0;41m'
    declare -gr GREENB='\033[0;42m'
    declare -gr YELLOWB='\033[0;43m'
    declare -gr BLUEB='\033[0;44m'
    declare -gr PURPLEB='\033[0;45m'
    declare -gr CYANB='\033[0;46m'
    declare -gr GRAYB='\033[0;47m'
    exp_vars+=( BOLD RST BLINK INV UND BLACK RED GREEN YELLOW BLUE MAGENTA WHITE CYAN GRAY WHITE BLACKB REDB GREENB YELLOWB BLUEB PURPLEB CYANB GRAYB )

    if which colordiff 1>/dev/null 2>/dev/null; then
        diff_=colordiff
    else
        diff() {
            typeset r=0
            typeset res
            res="$( $diff_ "$@" | sed -re "s;^([+].*)$;\\${GREEN}\1\\${RST};;s;^([-].*)$;\\${RED}\1\\${RST};" )"
            r=$?
            echo -e "$res"
            return $r
        }
    fi
}
exp_cmds+=( diff )

OK=OK
FAILED=FAILED
FATAL=FATAL
TODO=TODO
MSG_STATUS=
QUIET=
SHOW_OUTPUT=
SHOW_FAILED=

exp_vars+=( OK FAILED FATAL TODO QUIET DEBUG )

r_ok=0
r_fail=1
r_fatal=2
r_fatal2=5
r_warn=3
r_todo=4
exp_vars+=( r_ok r_fail r_fatal r_warn r_todo )

echo_c() {
    local s=$1; shift
    case "$s" in
        FAILED|FATAL|SYNTAX) echo -e "${BOLD}${RED}${BLINK}$@${RST}";;
        WARNING|WARN) echo -e "${RED}${BLINK}$@${RST}";;
        OK) echo -e "${BOLD}${BLUE}$@${RST}";;
    esac
}

fail() {
    [[ -n "${1:-}" ]] && echo "[$FAILED] $@"
    return $r_fail
}
ok() {
    [[ -n "${1:-}" ]] && echo "[$OK] $@"
    return $r_ok
}
fatal() {
    [[ -n "${1:-}" ]] && echo "[$FATAL] $@" >&2
    return $r_fatal
}
todo() {
    echo -ne "${YELLOW}[$TODO]${@+ ${BOLD}${CYAN}$@}${RST}" >&2
    exit $r_todo
}

dbg() {
    ((!QUIET && DEBUG)) && echo -e "${INV}${BOLD}[DBG]${RST} ${BOLD}${WHITE}$@${RST}" >&2
    return 0
}
DBG() {
    ((DEBUG_BTS)) && echo -e "${INV}${BOLD}${BLUE}[BTS]${RST} ${BOLD}${WHITE}$@${RST}" >&2
    return 0
}
trace() {
    echo "$@" >&2
}
exp_cmds+=( fail ok fatal todo dbg trace )

export_cmds() {
    for c in ${exp_cmds[@]} 'setup' 'teardown'; do
        typeset -f "$c"
    done
    typeset vars=""
    for v in ${exp_vars[@]}; do
        vars+="export $v=\"${!v}\";"
    done
    echo "${vars%;}"
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
    local sf=${f##*/}
    [[ "$1" == NOT || "$1" == not ]] && NOT=1 && shift
    local is_not=$( ((NOT)) && echo 'NOT ' )
    local a="$1"; shift
    local res1 res2 r
    case "${a^^}" in
        TRUE|FALSE|EQUALS|SAME|SAME~|EXISTS|FILE~|FILE|SAMECOL|SAMECOL~) a=${a^^};;
        *) echo "unknown assertion '$a' (${sf}:${FUNCNAME[1]}:${BASH_LINENO[0]})"; return $r_fail;;
    esac
    set -- "$@"
    [[ -z "${@+z}" ]] && echo_c SYNTAX "Missing evaluation!" && exit 1
    local cmp="${1:-}"
    local exp="${2:-}"; [[ ! "${2+x}" == "x" ]] && unset exp
    local cmp_f exp_f
    local cmp_diff
    case $a in
        TRUE|FALSE)
            [[ -n "$cmp" && ! "$cmp" =~ ^[0]+$ && ! "$cmp" =~ ^[\t\ ]*[Ff][Aa][Ll][Ss][Ee][\t\ ]*$ ]] && {
                [[ "$cmp" =~ ^[\t\ ]*[Tt][Rr][Uu][Ee][\t\ ]*$ || "$cmp" == "1" ]] && r=0 || {
                    cmp="$@"; unset exp
                    (eval "$@";) && r=0
                }
            } || r=1
            [[ "$a" == FALSE ]] && r=$((!r));;
        EQUALS) [[ "$cmp" == "$exp" ]] && r=0 || r=1;;
        FILE~) local dn="$(dirname "$cmp")"; find "$dn" -maxdepth 1 -regex "$dn/$(basename "$cmp")" 2>/dev/null| grep -q '.' && r=0 || r=1;;
        FILE)  [[ -e "$cmp" ]] && r=0 || r=1;;
        EXISTS) [[ -n "$cmp" ]] && {
                    ! [[ "$cmp" =~ ^[$] ]] && r=0 || {
                        local xv="${cmp#$}"
                        local xval=${!xv}
                        [[ -n "$xval" ]] && r=0
                    }
                } || r=1;;
        SAME)
            [[ -e "$exp" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(diff -u ${exp_f:-<(echo "$2")} ${cmp_f:-<(echo "$1")} 2>/dev/null) && r=0 || r=1;;
        SAME~)
            [[ -e "$exp" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(diff -u <(sort ${exp_f:-<(echo "$2")}) <(sort ${cmp_f:-<(echo "$1")}) 2>/dev/null) && r=0 || r=1;;
        SAMECOL)
            local col="${3:-1}"
            local sep="${4:-;}"
            [[ -e "$exp" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(diff -u <( awk -F"${sep}" '{print $'${col}'}' ${exp_f:-<(echo "$2")} ) <( awk -F"${sep}" '{print $'${col}'}' ${cmp_f:-<(echo "$1")} ) 2>/dev/null) && r=0 || r=1;;
        SAMECOL~)
            local col="${3:-1}"
            local sep="${4:-;}"
            [[ -e "$exp" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(diff -u <( awk -F"${sep}" '{print $'${col}'}' <( sort -k${col} ${exp_f:-<(echo "$2")} ) ) <( awk -F"${sep}" '{print $'${col}'}' <( sort -k${col} ${cmp_f:-<(echo "$1")} ) ) 2>/dev/null) && r=0 || r=1;;

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
        ((SHOULD_FAIL && !DEBUG_BTS)) && return $r
        ((SHOULD_FAIL)) && failed_expected=' (expected)'
        echo -e "${INV}${RED}assertion failed${YELLOW}${failed_expected:-}${RST}: ${BLUE}${sf}${RST}:${WHITE}${UND}${func}${RST}:${BOLD}${CYAN}${INV}${line}${RST}:"

        local c="$( sed -n "${line}p" "$f" | sed -e 's/^[\t ]*\(.*\)$/\1/g')"
        echo "-> $c"
        echo "=> assert ${is_not}${a} '${cmp}' ${exp+'$exp'}"
        [[ "$a" == SAME || "$a" == SAME~ || "$a" == SAMECOL || "$a" == SAMECOL~ ]] && {
            echo
            echo -e "${YELLOW}expected${RST}${cmp_f:+ (from '$cmp_f')}:\n----------\n$(cat ${cmp_f:-<(echo "$cmp")})\n----------"
            echo -e "${YELLOW}got${RST}${exp_f:+ (from '$exp_f')}:\n----------\n$(cat ${exp_f:-<(echo $exp)})\n----------"
            [[ -n "$cmp_diff" ]] && {
                echo -e "${YELLOW}diff${RST}:\n$cmp_diff"
                echo "----------"
            }
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
    local sf="${f##*/}"
    local l_t="$2"
    local l_tests=( ${l_t:-${tests[@]}} )
    local setup="${tests_ext[setup]:-}"
    local teardown="${tests_ext[teardown]:-}"
    local preset="${tests_ext[preset]:-}"
    local reset="${tests_ext[reset]:-}"

    failed=0
    unimplemented=0
    total=${#l_tests[@]}; local s=""; ((total>1)) && s='s'

    ((!total)) && echo "No test found" && return $r_ok
    echo "Executing $total test$s"
    echo
    local n=0; local nn=0
    local _preset_executed=0
    local _end=$(( ${#l_tests[@]} ))
    local _cur=0
    local _is_last=0
    for t in ${l_tests[@]}; do
        ((++_cur >= _end)) && _is_last=1
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
                    DBG "IS A SHOULD"
                    line=${BASH_LINENO[1]}
                    func="${FUNCNAME[2]}"
                } || {
                    DBG "IS NOT A SHOULD"
                    line=${BASH_LINENO[0]}
                    func="${FUNCNAME[1]}"
                }
                fline="$line"
                [[ "$func" != "$t" && ! "$func" =~ \@should_ ]] && {
                    fline="[UNDEF]"
                    func="$t"
                }
                trap - ERR

                ## teardown & reset, anyway
                [[ -n "$teardown" ]] && {
                    $teardown || { echo "WARN: failed to execute '$teardown'!"; ((!retval)) && retval=$r_warn; }
                }
                ((_is_last)) && {
                    [[ -n "$reset" ]] && {
                        $reset || { echo "WARN: failed to execute '$reset'!"; ((!retval)) && retval=$r_warn; }
                    }
                }
                echo "--- [$( ((retval)) && echo $FAILED || echo $OK)]: $t --------"

                echo
                local err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n');
                local trc="(--> [${FUNCNAME[@]}, ${BASH_LINENO[@]}])"
                local t=( "Failed at ${sf}:${func}:${fline}" ": ${err_line:-$BASH_COMMAND}" "$trc" "TRAP TO RETURN $retval" )
                local max=0; for l in "${t[@]}"; do s=${#l}; (( s > max )) && max=$s; done; ((max+=4))
                echo -e "${BOLD}${BLUE}-- traces ------------${RST}"
                for l in "${t[@]}"; do
                    printf "${YELLOWB}    ${BLACK}%-${max}s${RST}\n" "$l"
                done

                exec 1>&8
                exec 2>&9
                exec 7>&-

                return $retval
            }
            trap '_trap_err' ERR
            
            command_not_found_handle() {
                local line=${BASH_LINENO[0]}
                local err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n')
                echo -e "FATAL: command not found: ${sf}:${FUNCNAME[1]}:${BASH_LINENO[0]}:\n -> $err_line"
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
        echo -e "${INV}Running test class ${BOLD}${CYAN}$fr${RST}"
        _run_tests "$ff" "$t"
        echo
        echo -e "-> [$((total-failed))/$total] ($failed failure$(((failed>1)) && echo s)$(((unimplemented)) && echo ", $unimplemented being unimplemented test$(((unimplemented>1))&& echo s)"))"
    done
}

ARGS=()
TEST_DIR=tests
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0;;
        -vv|--very-verbose) SHOW_OUTPUT=1;;
        -v|--verbose) SHOW_FAILED=1;;
        -C|--no-color) NO_COLORS=1;;
        -c|--color) NO_COLORS=0;;
        -dd|--extra-debug) DEBUG=2;;
        -d|--debug) DEBUG=1;;
        -D|--DEBUG) DEBUG_BTS=1;;
        -q|--quiet) QUIET=1; SHOW_FAILED=0;;
        -qq|--very-quiet|-s|--silent) QUIET=1; SHOW_FAILED=0; SHOW_OUTPUT=0;;
        -l|--list|--list-tests) LIST_ONLY=1;;
        -t|--tests-dir) TEST_DIR="$2"; shift;;
        #-i|--interactive) LIST_ONLY=1; INTERACTIVE=1;;
        *) ARGS+=( "$1" );;
    esac
    shift
done
!((NO_COLORS)) && _set_colors
set -- "${ARGS[@]}"
## no tests found
! [[ -d "$TEST_DIR" ]] && echo "Nothing to test" && exit 0

test_list="${@:-$here/$TEST_DIR/[0-9]*.sh}"
run
