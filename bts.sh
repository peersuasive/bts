#!/usr/bin/env bash
# vim: ts=4 sts=4 sw=4 expandtab

set -euo pipefail

## keep relative, because readlink would resolve with an unreachable path if bts.sh is a symlink
# well relative whould work very well either, would it? so, we don't care.
typeset bts_cmd="$0"
if command -v realpath 1>/dev/null 2>/dev/null; then
    bts_cmd="$(realpath -s "$0")"
else
    typeset _tmp_path; _tmp_path="$(dirname "$0")"
    if [[ "${_tmp_path:0:1}" != "/" ]]; then
        _tmp_path="${PWD}/${_tmp_path}"
    fi
    bts_cmd="$( readlink -f "$_tmp_path" )/$(basename "$0")"
    unset _tmp_path
fi
typeset -r bts_cmd

ORIG_ARGS=()
DEBUG=${DEBUG:-0}
DEBUG_BTS=${DEBUG_BTS:-0}
FIRST_FAIL=0
PRETTY_NAME=1
RAW_RUN=0
CLEAN_UP=0
NO_CONTAINERS=0

typeset __rnd="$RANDOM"
typeset -rx __bts_tmp_dir="/tmp/__bts_tmp_dir.__$__rnd"
typeset -rx _test_tmp_dir="/tmp/__bts_tmp.$__rnd"
unset __rnd
#mkdir -p "$__bts_tmp_dir" "$_test_tmp_dir"

__bts_trap_exit() {
    local retval=$?
    ## TODO before deleting temps, move results to ./reports!
    #if (( ! retval )); then
        \rm -rf "$__bts_tmp_dir" "$_test_tmp_dir"
    #fi
    exit $retval
}
trap '__bts_trap_exit' EXIT

## try to use bash's 4.4+ Parameters Transformations to keep empty arguments by quoting them
bts_bash_tr=0
(( "${BASH_VERSINFO[0]:-0}${BASH_VERSINFO[1]:-0}" > 43 )) && bts_bash_tr=1;
export bts_bash_tr

usage() {
#readarray msg <<EOU
    cat <<EOU
Usage: ${0##*/} [-h] [OPTIONS] [test...]

Usage notes:
    Tests are expected to be found in folder 'tests/' (see '-t' option),
    named as '[NN].<test>.sh'; ex.: tests/00.bts_tests.sh.

    Results are stored in 'reports/[TEST CLASS]/[TEST NAME].log'
    Tests classes are to be stored in 'tests/[0-9]*.test_name.sh'
    Tests starting with underscore (_) or arobase (@) are ignored.
    Tests are executed in order.

Options:
    -h|--help               show this message and exit
    -P|--no-pretty-name     show real test name instead of pretty name
    -v|--verbose            show output in case of failure only (default)
    -vv|--very-verbose      always show output
    -q|--quiet              don't show output, even in case of failure
    -qq|--very-quiet
    -s|--silent             don't show any output at all
    -l|--list|--list-tests  list available test without executing
    -t|--tests-dir <dir>    look for tests in 'dir' instead of 'tests'
    -r|--project-root <dir> project's base root (default: .)
    -f|--first-fail         break at first fail
    -D|--DEBUG              debug BTS
    -dd|--extra-debug       enable extra dbg traces (typically, turns 'set -x' on)
    -d|--debug              enable dbg traces
    --clean                 clean everything possible bts might have been produced and exit, that is: containers, temporary files & (current projects, if any) reports
    --no-container          disable use of containers
    

Utils (functions):
    setup    run before each test
    teardown run after each test
    preset   run before first test
    reset    run after last test
    fail     exit test immediatly with a failure (FAIL) message
    ok       exit test immediatly with a success (OK) message
    todo     exit test immediatly with a TODO message; this is accounted as a failure but notified as an unimplemented test also
    assert <COMMAND> <expression>
        true     assert evaluation is true
        false    assert evaluation is false
        ok       assert call returned 0
        ko       assert call returned 1
        equals   assert left string equals expected right string
        empty    assert result output is empty
        same     assert left string or file contents equals expected right string or file contents
        same~    assert left string or unordered file contents equals expected right string or unordered file contents
        samecol  compare same column from two files; column number and separator can be passed after files (default: column 1, comma (;) as separator)
        samecol~ compare same column from two unordered files; column number and separator can be passed after files (default: column 1, comma (;) as separator)
        exists   assert contents exist
        file|dir assert file or directory exists
        file~|dir~
                 same as file|dir but accepts regular expressions
        log|err|warn
                 assert last log or error log contains expression
    asset [-n] <asset[.gz|bz2]> [dest-dir|dest-file]
           -n    return full path to ressource, instead of contents

        tries its best to find file in 'TEST_DIR/assets/[test_name]...' and send it to destination or stdout
    @should_fail <expression>
        assert next evaluation fails as expected
    @capture_logs (obsolete)
        capture logs (can be used with assert log/err/warn)
    @export_var
        export a variable into test environment (useful when using another function called in test environment to check a value)

Utils (class)
    @load                       load a file relative to test dir; useful to load common tests or functions, for instance
    @bts_cont [0|false|1|true|<Dockerfile>] [container-name]
              -d|--dockerfile <dockerfile>
              -c|--cont-name <container_name>
              -u|--unit-tests
              -v|--volumes <path[,path> (eg., /tmp/mytests,/var/logs/apache)
 
               0|false: disable @bts_cont
               1|true: enable @bts_cont (default)
               -u: use container in unit-tests mode (see @bts_unit_cont)
               -v: folders to mount as volumes in container

        run tests inside a container
        (note: requires docker to be installed)

        A Dockerfile needs to be provided to this command to work.
        BTS will look for 'Dockerfile.bts' (or the provided filename) at the root of the project.
        NOTE on containers: BTS expects some GNU commands to be installed and doesn't work well with BusyBox.
                            Required (GNU) tools are: grep, sed, find, mktemp.
                            This is usually solved by installing 'coreutils', 'sed' and 'findutils' packages.

        An image will be created under bts/{project-name}/{test-name}, unless a container-name has been provided, in which case this last one will be used instead.

    @bts_unit_cont [1|0|<Dockerfile>]
        same as @bts_cont but each test is run in a separate container
        (note: this is a wrapper actually calling @bts_cont --unit-tests)

        note: internally, these containers are run with podman.
        A docker volume, bts_cont, will be created to host associated images. Images will be automatically updated if the referenced Dockerfile has been modified.
        As this volume will grow up in time, it's recommended to purge it when using too much space! It'll be recreated on the fly when required.

        An image will be stored under bts/unit:latest. This image is used to run bts in a main container before calling each test individually with their own container.
        This image is updated automatically when required.

    mock_funcs/__mock_funcs
        load mockup functions; syntax: mockup_function[:alias]; ex., __mock_funcs='__crontab:crontab'
        this is mainly usefull when loading an environment before starting a new shell; for eg., ksh or another bash, etc.

        mock_funcs will print mocked functions & bodies (to redirect in a file or to load with eval, for instance).

Other
    .btsignore  bts will ignore _tests_ declared in this file -- one per line, no glob or regex; reminder: bts ignores anything not matching [0-9]*.sh anyway

Debug/trace:
    trace    display message in output (logged)
    dbg      display a dbg message in output (logged)
EOU
    #printf "%s" "${msg[*]}"
}

exp_vars=()
exp_cmds=()
exp_utils=()

## ----------------------- lib
declare RST BLINK INV BLUE RED GREEN YELLOW MAGENTA WHITE CYAN GREY
diff_=$(which diff) || { fatal "Can't find 'diff' command!"; exit 1; }
bts_diff() {
    $diff_ "$@"
}
# shellcheck disable=SC2034
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
    declare -gr GREY='\033[37m'
    declare -gr WHITE='\033[97m'
    declare -gr BLACKB='\033[0;40m'
    declare -gr REDB='\033[0;41m'
    declare -gr GREENB='\033[0;42m'
    declare -gr YELLOWB='\033[0;43m'
    declare -gr BLUEB='\033[0;44m'
    declare -gr PURPLEB='\033[0;45m'
    declare -gr CYANB='\033[0;46m'
    declare -gr GREYB='\033[0;47m'
    exp_vars+=( BOLD RST BLINK INV UND BLACK RED GREEN YELLOW BLUE MAGENTA WHITE CYAN GREY WHITE BLACKB REDB GREENB YELLOWB BLUEB PURPLEB CYANB GREYB )

    if which colordiff 1>/dev/null 2>/dev/null; then
        diff_=colordiff
    else
        bts_diff() {
            typeset r=0
            typeset res
            res="$( $diff_ "$@" | sed -re "s;^([+].*)$;\\${GREEN}\1\\${RST};;s;^([-].*)$;\\${RED}\1\\${RST};" )"
            r=$?
            echo -e "$res"
            return $r
        }
    fi
}
exp_cmds+=( bts_diff )

OK=OK
FAILED=FAILED
WARNING=WARNING
FATAL=FATAL
TODO=TODO
INTERRUPTED=INTERRUPTED
DISABLED=DISABLED
MSG_STATUS=
QUIET=
SHOW_OUTPUT=
SHOW_FAILED=
VERBOSE=

exp_vars+=( OK FAILED FATAL TODO QUIET DEBUG )

r_ok=0
r_fail=1
r_fatal=2
r_fatal2=5
r_warn=3
r_todo=4
r_cnf=6
r_break=9
r_syntax=10
r_disabled=11
exp_vars+=( r_ok r_fail r_fatal r_warn r_todo r_break r_syntax)

echo_c() {
    local s=$1; shift
    case "$s" in
        FAILED|FATAL|SYNTAX) echo -e " \u21d2 ${BOLD}${RED}${BLINK}[$*]${RST}";;
        WARNING|WARN) echo -e " \u21d2 ${RED}${BLINK}[$*]${RST}";;
        OK) echo -e " \u21d2 ${BOLD}${BLUE}[$*]${RST}";;
    esac
}
echo_out() {
    local n
    [[ "$1" == -n ]] && n=1 && shift
    echo -e${n:+n} "$@"
}
echo_o() {
    echo_out "$@" >&4
}
echo_e() {
    echo_out "$@" >&5
}

fail() {
    [[ -n "${1:-}" ]] && echo "[$FAILED] $*"
    return $r_fail
}
ok() {
    [[ -n "${1:-}" ]] && echo "[$OK] $*"
    return $r_ok
}
fatal() {
    [[ -n "${1:-}" ]] && echo "[$FATAL] $*" >&2
    return $r_fatal
}
todo() {
    echo -ne "${YELLOW}[$TODO]${*+ ${BOLD}${CYAN}$*}${RST}" >&2
    exit $r_todo
}

dbg() {
    ((!QUIET && DEBUG)) && echo -e "${INV}${BOLD}[DBG]${RST} ${BOLD}${WHITE}$*${RST}" >&1
    return 0
}
DBG() {
    ((DEBUG_BTS)) && echo -e "${INV}${BOLD}${BLUE}[BTS]${RST} ${BOLD}${WHITE}$*${RST}" >&1
    return 0
}

## TODO display at the bottom, with tput, etc.
trace() {
    echo "$@" >&2
}
ltrace() {
    echo "$@" >&9
}
stdout() {
    echo "$@" >&7
}
stderr() {
    echo "$@" >&8
}
exp_cmds+=( stdout stderr )

asset() {
    local filename_only=0
    [[ "${1:-}" == -n ]] && filename_only=1 && shift
    local _a="${1:-Missing asset name}"
    local d="${2:-}"
    local a
    if [[ -e "$TEST_DIR/assets/${_a}" ]]; then
        a="$TEST_DIR/assets/${_a}"
    else
        a=$(find "$TEST_DIR/assets/${__bts_this_class}" -maxdepth 1 -regextype egrep \
            -regex "$TEST_DIR/assets/${__bts_this_class}/${__bts_test_name}[_.]+${_a}(.gz|.bz2)?" \
            -or \
            -regex "$TEST_DIR/assets/${__bts_this_class}/${_a}(.gz|.bz2)?" 2>/dev/null | grep '.' \
            || find "$TEST_DIR/assets" -maxdepth 1 -regextype egrep \
            -regex "$TEST_DIR/assets/${t}[_]*${_a}(.gz|.bz2)?" \
            -or \
            -regex "$TEST_DIR/assets/${_a}(.gz|.bz2)?" 2>/dev/null | grep '.'
            ) || {
                echo "Can't find asset '$_a' in '$TEST_DIR/assets/${__bts_this_class}' nor '$TEST_DIR/assets'" >&2
                return 1
            }
    fi
    ((filename_only)) && echo "$a" && return 0
    local unc=cat
    local ext=."${a##*.}"
    [[ "$ext" == ".gz" ]] && unc=$(which gzcat || which zcat)
    [[ "${a}" == ".bz2" ]] && unc=bzcat

    if [[ -d "$d" ]]; then
        $unc "$a" > "$d/${_a"%${ext}"}"
    elif [[ -z "$d" ]]; then
        $unc "$a"
    else
        $unc "$a" > "$d"
    fi
}

exp_cmds_pre+=( fail ok fatal todo dbg trace ltrace )

@escape_parameters() {
    if (( bts_bash_tr )); then
        echo "${@@Q}"
    else
        printf "%q " "$@"
    fi
}

@load() {
    local f="$1"; shift
    local args="${*:-}"
    local abs_path; abs_path="$(readlink -m "${__BTS_TEST_DIR}/$f")"
    set -- "$args"
    # shellcheck disable=SC1090
    source "$abs_path"
}

@todo() {
    echo "unimplemented: ${FUNCNAME[1]}"
    return $r_todo
}

typeset -A __bts_test_vars
@export_var() {
    local v val
    for v in "$@"; do
        val="${!v}"
        __bts_test_vars["$v"]="$val"
    done
}
exp_utils+=( "@export_var" )

BTS_CAPTURED_ERR=
BTS_CAPTURED_OUT=
@capture_logs() {
    local err_log=""
    local out_log=""
    local args=()
    while (($#)); do
        case "$1" in
            -e) err_log="$2"; shift;;
            -o) out_log="$2"; shift;;
            *) args+=( "$1" )
        esac
        shift
    done
    [[ -z "$err_log" ]] && {
        BTS_CAPTURED_ERR="$(mktemp)"
        err_log="$BTS_CAPTURED_ERR"
    }
    [[ -z "$out_log" ]] && {
        BTS_CAPTURED_OUT="$(mktemp)"
        out_log="$BTS_CAPTURED_OUT"
    }
    : > "$out_log"
    : > "$err_log"

    exec 8>&1
    exec 9>&2
    exec 1>"$out_log"
    exec 2>"$err_log"
    local r=0
    ## capture and re-throw for bts
    #! eval "$(printf "%q " "${args[@]}")" 1> >(tee "$out_log") 2> >(tee "$err_log" >&2) && r=1
    if ((${#args[@]} == 1)); then
        eval "${args[*]}" || r=1
    else
        eval "$(printf "%q " "${args[@]}")" || r=1
    fi

    #[[ -s "$out_log" ]] && cat "$out_log" >&1
    #[[ -s "$err_log" ]] && cat "$err_log" >&2
    exec 1>&8
    exec 2>&8
    exec 8>&-
    exec 9>&-

    return $r
}

BTS_CONT=0
BTS_CONT_NAME=
BTS_CONT_CAN_SHARE=0
BTS_UNIT_CONT=0
BTS_VOLUMES=
WITHIN_CONT=${WITHIN_CONT:-0}
WITHIN_CONT_NAME="${WITHIN_CONT_NAME:-}"
WITHIN_CONT_TAG="${WITHIN_CONT_TAG:-}"
WITHIN_UNIT_CONT=${WITHIN_UNIT_CONT:-0}
WITHIN_CONT_VOLUMES="${WITHIN_CONT_VOLUMES:-}"
__BTS_CONT_DISABLED=0
#SHARED_CONT=${SHARED_CONT:-0}
### load all tests together within a container
## @bts_cont [enabled:1 (default)|disabled:0|Dockerfile to use (defaults: Dockerfile.bts)] [container_name]
# returns
# BTS_CONT: Dockerfile to use (defaults to Dockerfile.bts)
# BTS_CONT_NAME: name of the container to use (defaults: empty)
# BTS_CONT_CAN_SHARE: if BTS_CONT is equal to Dockerfile.bts, set to 1 (default: 0)
# @bts_cont [-c|--container-name <cont_name>] [-u|--unit-tests] [0|1|false|true|<dockerfile>]
@bts_cont() {
    ## reset
    BTS_CONT=0
    BTS_CONT_NAME=""
    BTS_CONT_CAN_SHARE=0
    __BTS_CONT_DISABLED=0
    BTS_UNIT_CONT=0

    local cont_name=""
    local unit_cont=0
    local dockerfile=""
    local volumes=""
    local args=()
    while (($#)); do
        case "$1" in
            -c|--container-name) cont_name="$2"; shift;;
            -u|--unit-tests) unit_cont=1;;
            -d|--dockerfile) dockerfile="$2"; shift;;
            -v|--volumes) volumes="$2"; shift;;
            -*) echo "Unknown option: '$1'"; exit $r_syntax;;
            *) args+=( "$1" );;
        esac
        shift
    done
    set -- "${args[@]:-}"

    cont_state="${dockerfile:-${1:-}}"
    if [[ "${cont_state,,}" == "false" || "$cont_state" == 0 ]]; then __BTS_CONT_DISABLED=1; return 0; fi
    if [[ "${cont_state,,}" == "true" || "$cont_state" == 1 ]]; then cont_state=""; fi
    [[ -z "${cont_state:-}" ]] && BTS_CONT="Dockerfile.bts" || BTS_CONT="$cont_state"

    ! [[ -f "$BTS_CONT" ]] && echo "${FUNCNAME[*]}: Can't find dockerfile: '$BTS_CONT'" >&2 && exit $r_fatal

    [[ "$BTS_CONT" == "Dockerfile.bts" && -z "$cont_name" ]] && BTS_CONT_CAN_SHARE=1
    BTS_CONT_NAME="${cont_name:+bts/${cont_name#bts/}}"
    BTS_UNIT_CONT="${unit_cont:-0}"

    return 0
}
### load each test into its own container
@bts_unit_cont() {
    @bts_cont --unit-tests "$@"
}

@mktmp() {
    \mkdir -p "$_test_tmp_dir"
    \mktemp -dp "$_test_tmp_dir"
}

exp_utils+=( @load @bts_cont @bts_unit_cont @escape_parameters @mktmp )

__wants_container() {
    grep -qP '^[[:space:]]*@bts_(unit_)?cont[[:space:]]*(?:(?!0|false).)*$' "$1"
}

export_cmds() {
    for c in 'setup' 'teardown' ${exp_cmds[@]}; do
        typeset -f "$c"
    done
    for c in ${exp_cmds_pre[@]}; do
        typeset -f "$c" | sed -e 's;'"${c#bts_}"' ();bts_'"${c}"' ();'
    done
    typeset vars=""
    for v in ${exp_vars[@]}; do
        vars+="export $v=\"${!v}\";"
    done
    echo "${vars%;}"
}

export_utils() {
    for c in ${exp_utils[@]}; do
        typeset -f "$c"
    done
}

mock_funcs() {
    if [[ -n "${__mock_funcs:-}" ]]; then
        for fn in $__mock_funcs; do
            local fn_name=${fn%%:*}; local fn_alias=${fn##*:}
            typeset -f "$fn_name"
            if [[ "$fn_alias" != "$fn_name" ]]; then
                echo "alias -p $fn_alias='$fn_name'"
                echo "export $fn_alias"
            fi
        done
    fi
}

export SHOULD=0
export SHOULD_FAIL=0
@should_fail() {
    #local cmd="$1"; shift;
    local args=( "$@" )
    SHOULD=1
    SHOULD_FAIL=1
    #exec 9>&2
    #exec 2> >( echo -n "@should_fail (expected): " >&9; tee >&9)
    if (($#>1)); then
        if (( bts_bash_tr )); then
            ( trap - ERR; (! eval "${args[*]@Q}") ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
        else
            ( trap - ERR; (! eval "$(printf "%q " "${args[@]}")") ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
        fi
    else
        ( trap - ERR; (! eval "${args[*]}") ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
    fi
    #exec 2>&9
    #exec 9>&-
    # shellcheck disable=SC2119
    fail
}

assert() {
    local has_err=""
has_err=$(
    local NOT=0
    local sf=${f##*/}
    [[ "$1" == NOT || "$1" == not ]] && NOT=1 && shift
    local _not; _not=$( ((NOT)) && echo ' NOT' )
    local is_not; is_not=$( ((NOT)) && echo 'NOT ' )
    local a="$1"; shift
    local r=0
    local a_cap="${a^^}"
    case "${a_cap}" in
        OK|TRUE|KO|FALSE|EQUALS|EMPTY|MATCH|SAME|SAME~|EXISTS|FILE~|FILE|DIR|DIR~|SAMECOL|SAMECOL~|ERR|LOG|WARN)
            a="${a_cap}"
            ;;
        *) echo "unknown assertion '$a' (${sf}:${FUNCNAME[1]}:${BASH_LINENO[0]})"; return $r_fail;;
    esac
    ## unquote first! set -- "$@" whould quote again and coming from another call, like @should_fail, would have it quoted twice!
    #set -- "$( eval "echo $*" )"
    set -- "$@"
    ## quote/no-quote args...
    #local args; args="$(eval "echo \"$*\"")"
    local sub_cmd sub_args=""
    if (( $# == 1 )); then
        sub_cmd="$1"
    else
        sub_cmd="$1"
        local s_a
        for ((i=2;i<=$#;++i)); do
            s_a="${@:$i:1}"
            # ${s_a@Q} fails sometimes with 'bad substitution' for unknown reason
            sub_args+="$(printf "%q " "$s_a")"
        done
    fi
    #echo -e "subs: cmd: '$sub_cmd', args: '$sub_args'" >&2

    [[ -z "${*+z}" ]] && echo_c SYNTAX "Missing evaluation!" && exit 1
    local cmp="${1:-}"
    local exp="${2:-}"; [[ ! "${2+x}" == "x" ]] && unset exp
    local cmp_f exp_f
    local cmp_diff
    case "$a" in
        TRUE|FALSE)
            case "$cmp" in
                [Tt][Rr][Uu][Ee]) r=0;;
                [Ff][Aa][Ll][Ss][Ee]) r=1;;
                *)  if [[ "$cmp" =~ ^[\t\ ]*[-]?[0-9]+[\t\ ]*$ ]]; then
                        (( cmp > 0 )) && r=0 || r=1
                    else
                        cmp="$*"; unset exp; (eval "${*}";) && r=0 || r=1
                    fi
            esac
            [[ "$a" == FALSE ]] && r=$((!r))
            ;;
        OK|KO)
            case "$cmp" in
                [Oo][Kk]) r=0;;
                [Kk][Oo]) r=1;;
                *)  if [[ "$cmp" =~ ^[\t\ ]*[-]?[0-9]+[\t\ ]*$ ]]; then
                        (( cmp > 0 )) && r=1 || r=0
                    else
                        set -x
                        cmp="$*"; unset exp; (eval "${sub_cmd} ${sub_args}";) && r=0 || r=1
                        #cmp="$*"; unset exp; (eval "$*";) && r=0 || r=1
                        set +x
                    fi
            esac
            [[ "$a" == KO ]] && r=$((!r))
            ;;
        EQUALS) [[ "$cmp" == "$exp" ]] && r=0 || r=1;;
        FILE~|DIR~) local dn; dn="$(dirname "$cmp")"; find "$dn" -maxdepth 1 -regextype "posix-egrep" -iregex "$dn/$(basename "$cmp")" 2>/dev/null| grep -q '.' && r=0 || r=1;;
        FILE|DIR)  [[ -e "$cmp" ]] && r=0 || r=1;;
        EXISTS) [[ -n "$cmp" ]] && {
                    ! [[ "$cmp" =~ ^[$] ]] && r=0 || {
                        local xv="${cmp#$}"
                        local xval=${!xv}
                        [[ -n "$xval" ]] && r=0
                    }
                } || r=1;;
        EMPTY)
            assert same "" "$cmp" && r=0 || r=1
            ;;
        MATCH)
            echo "$exp" | grep -Eq "$cmp" && r=0 || r=1
            ;;
        SAME)
            [[ -e "${exp:-}" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(bts_diff -u ${exp_f:-<(echo -e "$2")} ${cmp_f:-<(echo -e "$1")} 2>/dev/null) && r=0 || r=1;;
        SAME~)
            [[ -e "${exp:-}" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(bts_diff -u <(sort ${exp_f:-<(echo -e "$2")}) <(sort ${cmp_f:-<(echo -e "$1")}) 2>/dev/null) && r=0 || r=1;;
        SAMECOL)
            local col="${3:-1}"
            local sep="${4:-;}"
            [[ -e "${exp:-}" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(bts_diff -u <( awk -F"${sep}" '{print $'${col}'}' ${exp_f:-<(echo -e "$2")} ) <( awk -F"${sep}" '{print $'${col}'}' ${cmp_f:-<(echo -e "$1")} ) 2>/dev/null) && r=0 || r=1;;
        SAMECOL~)
            local col="${3:-1}"
            local sep="${4:-;}"
            [[ -e "${exp:-}" ]] && exp_f="$exp"||:; [[ -e "$cmp" ]] && cmp_f="$cmp"||:;
            cmp_diff=$(bts_diff -u <( awk -F"${sep}" '{print $'${col}'}' <( sort -k${col} ${exp_f:-<(echo -e "$2")} ) ) <( awk -F"${sep}" '{print $'${col}'}' <( sort -k${col} ${cmp_f:-<(echo -e "$1")} ) ) 2>/dev/null) && r=0 || r=1;;

        LOG|ERR)
            local logs
            [[ "$a" == LOG ]] \
                && read -ra logs <<< "${BTS_CAPTURED_OUT:-} ${BTS_TEST_LOG:-}" \
                || read -ra logs <<< "${BTS_CAPTURED_ERR:-} ${BTS_TEST_ERR_LOG:-}"
            local _filled=0
            for l in "${logs[@]}"; do
                [[ -s "$l" ]] && _filled=1 && break
            done
            if ((_filled)); then
                ## implementation note: even if one of these files doesn't exist, grep with -q will return 0 if something's found! handy!
                # this might be a bug, though, not a feature, so some future release may fix it...
                if ! (grep -qF "$cmp" "${logs[@]}" 2>/dev/null || grep -qE "$cmp" "${logs[@]}" 2>/dev/null); then
                    exp="$(cat "${logs[@]}")"
                    r=1
                else
                    r=0
                fi
            fi
            ;;
        WARN)
            (assert err "$cmp" || assert log "$cmp") 1>/dev/null 2>/dev/null && r=0 || {
                exp=$(cat "$BTS_CAPTURED_OUT" "$BTS_CAPTURED_ERR" 2>/dev/null)
                r=1
            }
            ;;
        *)
            echo "Unknown assertion '$a' !!!" >&2
            exit $r_syntax
            ;;
    esac
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

        local c; c=="$( sed -n "${line}p" "$f" | sed -e 's/^[\t ]*\(.*\)$/\1/g')"
        echo "-> $c"
        echo "=> assert ${is_not}${a} '${cmp}' ${exp+'$exp'}"
        [[ "$a" == SAME || "$a" == SAME~ || "$a" == SAMECOL || "$a" == SAMECOL~ || "$a" == EMPTY || "$a" == MATCH || "$a" == ERR || "$a" == LOG || "$a" == WARN ]] && {
            echo
            echo -e "${YELLOW}expected${_not}${RST}${cmp_f:+ (from '$cmp_f')}:\n----------\n$(cat ${cmp_f:-<(echo "$cmp")})\n----------"
            echo -e "${YELLOW}got${RST}${exp_f:+ (from '$exp_f')}:\n----------\n$(cat ${exp_f:-<(echo "${exp:-}")})\n----------"
            [[ -n "${cmp_diff:-}" ]] && {
                echo -e "${YELLOW}diff${RST}:\n$cmp_diff"
                echo "----------"
            }
        }
        return $r
    } || return 0
) && return 0 || {
    if [[ -n "${has_err:-}" ]]; then echo "$has_err"; fi
    return 1
}
}

## ------ params

LIST_ONLY=0
SHOW_OUTPUT=0
SHOW_FAILED=1
NO_COLORS=0
VERBOSE=0

home="$( dirname "$(readlink -f "$0")" )"
here="$(readlink -f "$PWD")"
guessed_project="$(basename "$here")"
reports_base="$here/reports"

## ------ functions
declare -a _class_tests=()
declare -A _class_bts_funcs=()
_get_class_tests() {
    local test_class="${1:?Missing tests class}"
    local test_name="${2:-}"
    _class_tests=()
    _class_bts_funcs=()

    ! [[ -s "$test_class" ]] && echo "Test class '$test_class' can't be found or is empty; skipping." && return 1

    ## evaluate script first
    ## implementation note: got rid of this, as script below will source it also an would fail equally, which is far enough
    # shellcheck disable=SC1090
    local r=0
    ( source "$test_class" 1>/dev/null ) || r=$?
    ((r)) && { echo "Failed to pre-load class '$test_class'!"; return 1; }

    ## run in a new shell to start with a clean environment, devoid of any foreign functions
    local xxx; xxx=$(cat <<EOS|bash
        $(export_utils)
        shopt -s extdebug
        source "$test_class" 1>/dev/null || { echo "Failed to pre-load class '$test_class'!"; exit 1; }
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
                echo "_class_bts_funcs[\${ee##*_}]=\"\$ee\";"
            } || echo "_class_tests+=( \${e##*:} );"
        done | grep -E '^(_class_tests\+=|_class_bts_funcs\[)' # discard user's echo
EOS
) || return 1 ## end of eval
    eval "$xxx"
    ! ((${#_class_tests[@]})) && echo "Warning: no tests found in '$test_class'."
    ## check provided tests exists
    if [[ -n "${test_name:-}" ]]; then
        local t_names="${test_name//,/ }"
        typeset -A test_i=()
        local t
        for t in "${_class_tests[@]}"; do test_i["$t"]="$t"; done
        for tn in $t_names; do
            [[ -n "${test_i["$tn"]:-}" ]] || {
                echo "No such test: '$tn' in class '$test_class'"
                echo "Available tests are:"
                echo
                echo -e "${_class_tests[*]}" | tr ' ' $'\n'
                exit $r_fatal;
            }
        done
    fi
    return 0
}

## message in a box 
typeset -x BOX_WIDTH=36
function __box_up {
    local title=""
    local colour=""
    local box_msg=()
    local box_width=${BOX_WIDTH:-36}
    local rounded=0
    local squared=0
    local thick=0
    local noborder=0
    _set_border() {
        case "$1" in
            rounded) rounded=1; thick=0; squared=0; noborder=0;;
            squared) rounded=0; thick=0; squared=1; noborder=0;;
            thick) rounded=0; thick=1; squared=0; noborder=0;;
            noborder) rounded=0; thick=0; squared=0; noborder=1;;
            *) rounded=1; thick=0; squared=0; noborder=0;;
        esac
    }
    while (($#)); do
        case "$1" in
            -t) title="$2"; shift;;
            -c) colour="$2"; shift;;
            -w) box_width="$2"; shift;;
            --border) _set_border "$2"; shift;;
            --rounded) _set_border "rounded";;
            --squared) _set_border "squared";;
            --thick) _set_border "thick";;
            --no-border) _set_border "noborder";;
            -e|--error) _set_border "thick"; colour="${colour:-$RED}";;
            *) box_msg+=( "$1" );;
        esac
        shift
    done
    
    ## default border style
    ! (( rounded || squared || thick || noborder )) && rounded=1

    local sep_t sep_b sep_r sep_l sep_l_t sep_l_b sep_r_t sep_r_b
    ## some glyphs...
    if (( squared )); then
        sep_t='─'
        sep_b='─'
        sep_r='│'
        sep_l='│'
        sep_l_t='┌'
        sep_r_t='┐'
        sep_l_b='└'
        sep_r_b='┘'
    elif (( rounded )); then
        sep_t='─'
        sep_b='─'
        sep_r='│'
        sep_l='│'
        sep_l_t='╭'
        sep_r_t='╮'
        sep_l_b='╰'
        sep_r_b='╯'
    elif ((thick)); then
        sep_t='━'
        sep_b='━'
        sep_r='┃'
        sep_l='┃'
        sep_r_t='┓'
        sep_l_t='┏'
        sep_r_b='┛'
        sep_l_b='┗'
    elif ((noborder)); then
        sep_t=''
        sep_b=''
        sep_r=''
        sep_l=''
        sep_r_t=''
        sep_l_t=''
        sep_r_b=''
        sep_l_b=''
    fi

    # discard special codes from string
    function get_raw_string {
        local s="${1:-}"
        [[ -z "$s" ]] && return 0
        echo -ne "$s" | sed -r "s/(\\033|\x1B)\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g"
    }

    # compute and display message, either with centered text or to add left padding
    function print_pad {
        local pre_pad_length=0
        local no_center=0
        local get_pad=0
        local msg=""
        while (($#)); do
            case "$1" in
                -p) pre_pad_length="$2"; shift;;
                -n) no_center=1;;
                -g) get_pad=1;;
                *) msg="$1";;
            esac
            shift
        done
        ## get msg without colours, to get its real length
        local raw_msg; raw_msg="$( get_raw_string "$msg" )"

        local pad_max=$(( box_width - ${#raw_msg} ))
        (( pad_max < 0 )) && pad_max=0
        local pad_r_length pad_l_length
        if ((no_center)); then
            pad_l_length=$pre_pad_length
            pad_r_length=$(( pad_max - pre_pad_length ))
            (( pad_r_length < 0 )) && pad_r_length=0
        else
            pad_l_length=$(( pad_max / 2 ))
            local pad_int=$(( pad_max - pad_l_length * 2))
            (( pad_int < 0 )) && pad_int=0
            pad_r_length=$(( pad_l_length + pad_int ))
        fi
        local pad_l pad_r
        pad_l=$( for ((i=0;i<pad_l_length;++i)); do echo -n ' '; done )
        pad_r=$( for ((i=0;i<pad_r_length;++i)); do echo -n ' '; done )
        echo -e "${pad_l}${msg}${pad_r}"
        if ((get_pad)); then
            echo "$pad_l_length"
            echo "$pad_r_length"
        fi
    }
    ## compute pre pad
    local h=()
    while IFS=$'\n' read -r l; do
        h+=( "$l" )
    done <<<"$(print_pad -g "$title")"
    local pre_pad="${h[1]}"

    ## check title length, increase box width if too long
    local _raw_l; _raw_l="$( get_raw_string "$title" )"
    if (( ( pre_pad + ${#_raw_l}) > box_width )); then
        box_width=$(( pre_pad + ${#_raw_l} + 2))
    fi
    if (( box_width != BOX_WIDTH )); then
        ## recompute pre_pad
        h=()
        while IFS=$'\n' read -r l; do
            h+=( "$l" )
        done <<<"$(print_pad -g "$title")"
        pre_pad="${h[1]}"
    fi

    ## check lines length
    for l in "${box_msg[@]}"; do
        local _raw_l; _raw_l="$( get_raw_string "$l" )"
        if (( ( pre_pad + ${#_raw_l}) > box_width )); then
            box_width=$(( pre_pad + ${#_raw_l} + 1 ))
        fi
    done
    ## top line
    echo -e "${colour}${sep_l_t}$( for ((i=0;i<box_width;++i)); do echo -n "${sep_t}"; done )${sep_r_t}${RST}"

    ## title
    # shellcheck disable=SC2207
    if [[ -n "$title" ]]; then
        echo -e "${colour}${sep_l}${RST}$(print_pad -n -p "$pre_pad" "${title}")${colour}${sep_r}${RST}"
        echo -e "${colour}${sep_l}${RST}$(print_pad -n -p "$pre_pad" "")${colour}${sep_r}${RST}"
    fi

    ## message
    for l in "${box_msg[@]}"; do
        echo -e "${colour}${sep_l}${RST}$(print_pad -n -p "$pre_pad" "${l}")${colour}${sep_r}${RST}"
    done

    ## bottom line
    echo -e "${colour}${sep_l_b}$( for ((i=0;i<box_width;++i)); do echo -n "${sep_b}"; done )${sep_r_b}${RST}"
}

## ----- main

__test_name=
_get_test_name() {
    local __t="$1"
    if ((!PRETTY_NAME)); then
        __test_name="${__t}"
    else
        __test_name="${__t#*test_}";
        ## double underscore are converted to colon
        __test_name="${__test_name//__/: }";
        __test_name="${__test_name//_/ }"
        ## double-double-underscore ____, means : __
        __test_name="${__test_name//: : /: __}"
        ## tripple underscore ___ means litteral underscore
        __test_name="${__test_name//:  /_}"
    fi
}

_build_test_image() {
    local r=0
    local test_class="$1"
    local test_name="$2"
    local cont_name="$WITHIN_CONT_NAME"
    local cont_file="${WITHIN_CONT_FILE:-Dockerfile.bts}"

    local cont_shared=0
    [[ "$cont_file" == "Dockerfile.bts" ]] && cont_shared=1
    local cont_tag="${test_name//:_}"

    local cont_build_tag
    (( cont_shared )) && cont_build_tag='latest' || cont_build_tag="$cont_tag"

    ## reset message
    function __reset_msg {
        local msg="${msg:-}"
        if ((r)); then
            msg+=" $FAILED"
            echo_o "\r$msg"
            echo_o -n "$CURRENT_MSG"
            return $r
        fi

        msg+=" $OK"
        echo_o -n "\r$msg"
        printf "\r%${#msg}s" "" >&4
        echo_o -n "\r$CURRENT_MSG"
    }

    local msg="Building image: '${cont_name}:${cont_build_tag}' (from '$cont_file')..."

    ## compute Dockerfile checksum
    local dockerfile_sum; dockerfile_sum="sha256:$(sha256sum "$cont_file" | awk '{print $1}')"
    ## check if descriptor has changed since last build
    local was_rebuilt=0
    local image_sum
    if ! image_sum="$(podman inspect --type=image -f '{{index .Config.Labels "bts.dockerfile.checksum" }}' "${cont_name}:${cont_tag}" 2>/dev/null | grep '.')" \
        || [[ "$image_sum" != "$dockerfile_sum" ]]
    then
        echo_o -n "\r${msg}"
        was_rebuilt=1
        ## create a tag instead of rebuilding image for tests sharing the same Dockerfile (problem: how to find out this is the same Dockerfile?...)
        ## some discrepency between existing container and wanted one, probably coming from a more recent -- force rebuild
        [[ -n "$image_sum" ]] && {
            podman rmi --force "$(podman inspect --type=image -f '{{ .ID }}'|cut -d':' -f1)" 1>/dev/null 2>/dev/null || true
            no_cache=1
        }
        ## (re)build container if needed, execute within
        local tcn=${test_class##*/}; tcn="${tcn%.sh}"
        local test_base="${__bts_tmp_dir}/$tcn"
        ! [[ -d "$test_base" ]] && mkdir -p "$test_base"
        local cont_log="${test_base}/${test_name}.log"
        local cont_log_err="${test_base}/${test_name}.err.log"
        (
            set -euo pipefail
            local rr=0
 
            podman build ${no_cache:+--no-cache} --label "bts.dockerfile.checksum=${dockerfile_sum}" \
                --build-arg "http_proxy=${http_proxy:-${HTTP_PROXY:-}}" \
                --build-arg "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
                --build-arg "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
                --build-arg "UID=$UID" \
                --build-arg "GID=$GID" \
                --build-arg TZ="$(cat /etc/timezone 2>/dev/null||echo 'Europe/Paris')" \
                -f "$cont_file" \
                -t "${cont_name}:${cont_build_tag}" . || rr=$?

            exit $rr
        ) 1>"$cont_log" 2>"$cont_log_err" || r=$?
        __reset_msg
        if (( r )); then
            echo "unit container failed to build" >&2
            [[ -s "$cont_log" ]] && cat "$cont_log" >&2
            [[ -s "$cont_log_err" ]] && cat "$cont_log_err" >&2
        fi
    fi

    ## update tag if shared image
    if ((!r && cont_shared)); then
        if (( was_rebuilt )) || ! podman inspect --type=image "${cont_name}:${cont_tag}" 1>/dev/null 2>/dev/null; then
            echo_o -n "\r${msg}"
            podman rmi "${cont_name}:${cont_tag}" 1>/dev/null 2>/dev/null || true
            podman tag "${cont_name}:latest" "${cont_name}:${cont_tag}" 1>/dev/null || r=$?
            __reset_msg
        fi
    fi
}

_run_raw_cont() {
    local test_call="$1"
    local test_class_file="${test_call%%:*}"
    local test_class="${test_class_file##*/}"
    test_class="${test_class%.sh}"
    local test_name="${test_call##*:}"

    _build_test_image "$test_class" "$test_name" || return $r_fatal

    local cont_tag="${test_name//:/_}"

    (
        exec 2> >(dos2unix)

        podman run --rm -i \
            -e "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
            -e "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
            -e TZ="$(cat /etc/timezone 2>/dev/null||echo 'Europe/Paris')" \
            -v "$PWD":"$PWD" \
            -v "/__bts_tmp:/__bts_tmp:ro" \
            -w "$PWD" \
        "localhost/${WITHIN_CONT_NAME}:${cont_tag}" "$bts_cmd" --raw "$test_call" | dos2unix
    )
}

## __bts_test_name & __bts_this_class are used by 'asset' command (and might be by some more in the future)
typeset -x __bts_this_class
typeset -x __bts_test_name
typeset -A test_classes
## this is called by run and also called directly when RUN_RAW is set
_run_raw() {
    ((DEBUG>1)) && echo "DDEBUG: $DEBUG" && set -x

    local test_call="$1"
    local test_class_file="${test_call%%:*}"
    local test_class="${test_class_file##*/}"
    test_class="${test_class%.sh}"
    local test_name="${test_call##*:}"

    __bts_this_class="$test_class"
    __bts_test_name="$test_name"

    if [[ "$test_name" == "$test_class" ]]; then
        echo "Missing test to run"
        return $r_fatal
    fi

    local bts_test_class_file="${__bts_tmp_dir}/${test_class}/${test_class}_bts.sh"
    if ! [[ -f "$bts_test_class_file" ]]; then
        ## TODO _prepare_class "$test_class_file"
        ## create bts's tmp. dir, it might be missing if called with --raw
        mkdir -p "${__bts_tmp_dir}"
        _get_called_tests "$test_call"
        _prepare_class "$test_class_file"
    fi

    local test_file="${__bts_tmp_dir}/${test_class}/${test_name}"
    ## check if file exists
    [[ -f "$test_file" ]]

    ## run bts.sh in a container or a sub-shell,
    # passing ORIG_ARGS and test_class:test_name
    (
        ## FIXME f... really... we should refactor this to 'current_test' or something more clear
        # this is used by assert, among others, probably
        export f="$test_class_file"
        # shellcheck disable=SC1090
        . "$test_file"
    )
}

_substitude_pseudo_vars() {
    local test_class_file="$1"
    local pat
    pat='s;%\{tests_dir\};'"${TEST_DIR}"';g;'
    pat+='s;%\{this\};'"${class_name}"';g;'
    pat+='s;%\{assets\};'"${TEST_DIR}/assets/${class_name}"';g;'
    pat+='s;%\{root_dir\};'"$(dirname "$(readlink -f "${TEST_DIR}")")"';g;'
    pat+='s;%\{assets_dir\};'"$(readlink -f "${TEST_DIR}/assets")"';g'
    sed -r "$pat" "$test_class_file"
}

## prepare test file
_prepare_class() {
    local test_class_file="$1"
    ## TODO prepare test: substitute %{...},
    # get rid of @load_cont (or set to ignore it?)
    local class_name="${test_class%.sh}"; class_name="${class_name##*/}"
    local __class_tmp_dir=${__bts_tmp_dir}/"$class_name"
    \mkdir -p "$__class_tmp_dir"
    local main_tmp_sh="${__class_tmp_dir}/${class_name}_bts.sh"

    _substitude_pseudo_vars "$test_class_file" > "$main_tmp_sh"

    (
        # shellcheck disable=SC1090
        . "$main_tmp_sh"

        local has_preset=0
        if typeset -F "preset" 1>/dev/null 2>/dev/null; then
            has_preset=1
        fi
        local has_setup=0
        if typeset -F "setup" 1>/dev/null 2>/dev/null; then
            has_setup=1
        fi
        local has_teardown=0
        if typeset -F "teardown" 1>/dev/null 2>/dev/null; then
            has_teardown=1
        fi

        for test_function in ${test_classes["$test_class_file"]}; do
            ## TODO fail safely if test not found and add to (yet to create) missing_tests list
            #typeset -f "$test_function" > "${__class_tmp_dir}/${test_function}"
            local bts_test_func="${__class_tmp_dir}/${test_function}"
            cat <<'HANDLERS' > "$bts_test_func"
            set -o pipefail
            set -eE
            set -o functrace
            _trap_exit() {
                local retval=$?
                exit $retval
            }
            trap '_trap_exit' EXIT
            _trap_break() {
                exit $r_break
            }
            trap '_trap_break' SIGINT
            trap '_trap_break' SIGTERM

            local has_teardown=0
            _trap_err() {
                local retval=$?

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
                [[ "$func" != "$test_name" && ! "$func" =~ \@should_ ]] && {
                    fline="[RETURN]"
                    func="$test_name"
                }
                trap - ERR

                ## teardown anyway
                ((has_teardown)) && {
                    "$teardown" || { echo "WARN: failed to execute '$teardown'!"; ((!retval)) && retval=$r_warn; }
                }

                echo "--- [$( ((retval)) && echo $FAILED || echo $OK)]: $test_name --------"
                echo
                local err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n');
                local trc="(--> [${FUNCNAME[*]}, ${BASH_LINENO[*]}])"
                local t=( "Failed at ${test_class}:${func}:${fline}" ": ${err_line:-$BASH_COMMAND}" "$trc" "TRAP TO RETURN $retval" )
                local max=0; for l in "${t[@]}"; do s=${#l}; (( s > max )) && max=$s; done; ((max+=4))
                echo -e "${BOLD}${BLUE}-- traces ------------${RST}"
                for l in "${t[@]}"; do
                    printf "${YELLOWB}    ${BLACK}%-${max}s${RST}\n" "$l"
                done

                exit $retval
            }
            trap '_trap_err' ERR

            command_not_found_handle() {
                local line=${BASH_LINENO[0]}
                local err_line; err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n')
                echo -e "FATAL: command not found: ${test_class}:${FUNCNAME[1]}:${BASH_LINENO[0]}:\n -> $err_line"
                exit $r_cnf ## useless, handle won't pass exit code
            }
HANDLERS
            echo ". \"$main_tmp_sh\"" >> "$bts_test_func"
            if ((has_preset)); then
                echo "if ! preset; then echo "Failed to run preset"; return $r_fatal; fi" >> "$bts_test_func"
            fi
            
            ## TODO get rid of pre-processing methods, like @bts_cont, etc.

            ## special variables, related to current test
            # we use both forms because one may be overwritten by the real function name, for instance if not being prefixed with test_
            echo "export ${test_function##test_}=1; export ${test_function##test_}__test=1" >> "$bts_test_func"
            echo "export __bts_current_test=\"$test_function\"" >> "$bts_test_func"

            ## export test's variables and reset __bts_test_vars
            for v in "${!__bts_test_vars[@]}"; do
                echo "export $v=\"${__bts_test_vars[$v]}\"" >> "$bts_test_func"
            done
            __bts_test_vars=()

            ## load specific env
            if [[ -f "${__bts_tmp_dir}/.env.bts" ]]; then
                echo "source \"${__bts_tmp_dir}/.env.bts\"" >> "$bts_test_func"
            elif [[ -f "/__bts_tmp/.env.bts" ]]; then
                echo "source \"/__bts_tmp/.env.bts\"" >> "$bts_test_func"
            fi

            ## load setup, teardown, etc.
            # ie., wrap and return specific error/code
            
            # run setup before test
            if ((has_setup)); then
                echo "if ! setup; then echo "Failed to run setup"; return $r_fatal; fi" >> "$bts_test_func"
            fi
            # run teardown anyway if declared
            if ((has_teardown)); then
                cat <<EOS >> "$bts_test_func"
                local r=0
                $test_function
                if ! teardown; then
                    echo "Failed to run teardown!"
                    (( r )) && return \$r || return $r_warn
                else
                    return \$r
                fi
EOS

            else
                echo "$test_function" >> "$bts_test_func"
            fi
        done
    )
}

_get_called_tests() {
    local test_list="${*:-$test_list}"

    local tests_to_ignore=""
    if [[ -f "$TEST_DIR/.btsignore" ]]; then
        tests_to_ignore="$(< "$TEST_DIR/.btsignore" xargs)"
    fi

    local t
    for t in ${test_list}; do
        local test_class test_name
        if [[ "$t" =~ ^([^:]+)[:]{0,1}(.*)$ ]]; then
            test_class="${BASH_REMATCH[1]}"
            test_name="${BASH_REMATCH[2]:-}"
            ## tests to ignore
            [[ " $tests_to_ignore " =~ \ ${test_class##*/}\  ]] && continue
            ! [[ -s "$test_class" ]] && echo "[WARNING] Missing test class '$test_class'; skipping" && continue
            if ! _get_class_tests "$test_class" "$test_name"; then
                echo "Failed to load tests class '$t'"
                continue
            fi
            [[ -z "$test_name" ]] && test_name="${_class_tests[*]}"

            test_classes["$test_class"]="$( (echo "$test_name"; echo "${test_classes["$test_class"]:-}")| tr ' ' $'\n'| sort -u | xargs)"
        else
            echo "Failed to get tests for '$t'"
            return 1
        fi
    done

    [[ -z "${test_classes[*]:-}" ]] || (( ${#test_classes[*]} == 0 )) && echo "No test to run" && return 1 || return 0
}

typeset failed=0
typeset unimplemented=0
typeset disabled=0
typeset missing=0
_manage_results() {
    local r=0
    local res="$1"
    local log_base="$2"
    local show_logs=${SHOW_OUTPUT:-0}
    case "$res" in
        0)
            echo_c OK "$OK" >&4
            ;;
        "$r_disabled")
            echo_c FATAL "$DISABLED" >&4
            ((++failed))
            ((++disabled))
            ;;
        "$r_break")
            echo_c FATAL "$INTERRUPTED" >&4
            exit $r_break
            ;;
        "$r_warn")
            echo_c WARNING "$WARNING" >&4
            ;;
        "$r_cnf")
            echo_c FAILED "$FAILED" >&4
            show_logs=1
            ((++failed))
            ;;
        "$r_todo") 
            echo_c WARNING "$TODO" >&4
            ((++unimplemented))
            ;;
        "$r_fatal" | "$r_fatal2")
            echo_c FATAL "$FATAL" >&4
            show_logs=1
            r=$r_fatal
            # or exit $r_fatal?
            ;;
        *)
            echo_c FAILED "$FAILED" >&4
            show_logs=1
            ((++failed))
            ;;
    esac

    ## display outputs if required
    if ((show_logs)); then
        if [[ -s "$log_base".log ]]; then
            echo -en "${GREY}" >&5
            cat "$log_base".log >&5
            echo -en "${RST}" >&5
        fi
        if [[ -s "$log_base".err.log ]]; then
            cat "$log_base".err.log >&5
        fi
    fi
    [[ ! -s "$log_base".err.log ]] && \rm -f "$log_base".err.log
    [[ ! -s "$log_base".log ]] && \rm -f "$log_base".log
    ## exit on first failure or pass break status with r=1
    (( res && res != "$r_disabled" && FIRST_FAIL )) && echo_e "ARG!!!!!!!!" && exit "$res"
    return $r
}

## build image shared by all tests of a class
__build_cont_image() {
    local test_class="$1"
    local bts_cont="${2:-Dockerfile.bts}"
    local cont_name="${3:-bts/$guessed_project/$guessed_project}"
    local is_shared=${bts_cont_can_share:-}
    [[ -z "${is_shared:-}" && "$bts_cont" == Dockerfile.bts ]] && is_shared=1

    ## TODO if shared but with a different name, we want to tag existing image with this tag
    # if image doesn't exist, we must build it first, but, still, name it after the project's name and then tag it
    local cont_tag="latest"
    if ((is_shared)); then
        :
    fi

    ## check assets
    ! [[ -f "$bts_cont" ]] && echo "Missing file '$bts_cont': can't build image according to requirements" && exit $r_fatal

    ## compute Dockerfile checksum
    local dockerfile_sum; dockerfile_sum="sha256:$(sha256sum "$bts_cont" | awk '{print $1}')"

    ## check if descriptor has changed since last build
    if image_sum="$(docker inspect --type=image -f '{{index .Config.Labels "bts.dockerfile.checksum" }}' "$cont_name" 2>/dev/null)" \
        && [[ "$image_sum" == "$dockerfile_sum" ]]; then
        return 0
    fi

    ## remove old image
    docker rmi "$cont_name" 2>/dev/null 1>/dev/null || true

    ## build image
    local GID="${GID:-$(id -g)}"
    local tn=${test_class##*/}; tn="${tn%.sh}"
    echo -n "[Preparing environment for ${tn}...]"
    (
        set -euo pipefail
        local test_base="${__bts_tmp_dir}/$tn"
        ! [[ -d "$test_base" ]] && mkdir -p "$test_base"
        local cont_log="${test_base}/container.log"
        local cont_log_err="${test_base}/container.err.log"
        exec 8>&1
        exec 9>&2
        exec 1>>"$cont_log"
        exec 2>>"$cont_log_err"
        
        local r=0

        docker build \
            ${no_cache:+--no-cache} --label "bts.dockerfile.checksum=${dockerfile_sum}" \
            --build-arg "http_proxy=${http_proxy:-${HTTP_PROXY:-}}" \
            --build-arg "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
            --build-arg "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
            --build-arg "UID=$UID" \
            --build-arg "GID=$GID" \
            --build-arg "LOGNAME=$LOGNAME" \
            --build-arg "GROUPNAME=$( getent group "$(getent passwd "$LOGNAME"| awk -F':' '{print $4}')"|awk -F':' '{print $1}' )" \
            --build-arg TZ="$(cat /etc/timezone 2>/dev/null||echo 'Europe/Paris')" \
            -t "$cont_name":"$cont_tag" \
            -f "$bts_cont" . || r=$?

        exec 1>&8
        exec 2>&9
        exec 8>&-
        exec 9>&-

        if ((r)); then
            echo -e "\r[Preparing environment for ${tn}... $FAILED]"
            echo "Container failed to build" >&2
            [[ -s "$cont_log" ]] && cat "$cont_log" >&2
            [[ -s "$cont_log_err" ]] && cat "$cont_log_err" >&2
        fi
        exit $r
    )
    echo -e "\r[Preparing environment for ${tn}... $OK]"
}

## build image for unit containers
__build_main_image() {
    local test_class="$1"
    ## re-build image only if something's been updated

    ## dump descriptor
    local dockerfile=${__bts_tmp_dir}/Dockerfile.main
    cat <<'DOCKERFILE' > "$dockerfile"
FROM alpine
ARG UID
ARG GID
ARG LOGNAME
ARG GROUPNAME

ARG http_proxy
ARG https_proxy
ARG TZ=Europe/Paris
ARG LC_ALL=en_US.UTF-8

ENV LC_ALL ${LC_ALL:-en_US.UTF-8}
ENV TZ ${TZ:-Europe/Paris}
ENV http_proxy=${http_proxy}
ENV https_proxy=${https_proxy}
ENV GID=${GID}
ENV LOGNAME=${LOGNAME}

RUN apk add --no-cache sudo podman ca-certificates bash musl-locales tzdata coreutils findutils lsb-release fuse-overlayfs \
    && cp /usr/share/zoneinfo/${TZ} /etc/localtime

RUN echo "${LOGNAME}:10000:65536" >> /etc/subuid \
    && echo "${GROUPNAME}:10000:65536" >> /etc/subgid

# create docker user and add them to sudoers
RUN addgroup -g "${GID}" ${GROUPNAME} && adduser -D -s /bin/bash -u "${UID}" -G ${GROUPNAME} ${LOGNAME} \
      && echo "${LOGNAME} ALL=(ALL) NOPASSWD:ALL" | tee /etc/sudoers.d/${LOGNAME} \
      && chmod 640 /etc/sudoers.d/${LOGNAME} \
      && mkdir -p /run/user/${UID} && chmod 700 /run/user/${UID} && chown -R ${UID}:${GID} /run/user/${UID}

USER ${LOGNAME}
RUN mkdir -p /home/${LOGNAME}/.local/share/containers
DOCKERFILE
    ## compute Dockerfile checksum
    local dockerfile_sum; dockerfile_sum="sha256:$(sha256sum "$dockerfile" | awk '{print $1}')"

    ## check if descriptor has changed since last build
    if image_sum="$(docker inspect --type=image -f '{{index .Config.Labels "bts.dockerfile.checksum" }}' "bts/unit" 2>/dev/null)" \
        && [[ "$image_sum" == "$dockerfile_sum" ]]; then
        return 0
    fi

    ## remove old image
    docker rmi bts/unit 2>/dev/null 1>/dev/null || true

    ## build pseudo docker-in-docker
    local GID="${GID:-$(id -g)}"
    local tcn=${test_class##*/}; tcn="${tcn%.sh}"
    echo -n "[Preparing environment for ${tcn}...]"
    (
        set -euo pipefail
        local test_base="${__bts_tmp_dir}/$tcn"
        ! [[ -d "$test_base" ]] && mkdir -p "$test_base"
        local cont_log="${test_base}/container_unit.log"
        local cont_log_err="${test_base}/container_unit.err.log"
        exec 8>&1
        exec 9>&2
        exec 1>>"$cont_log"
        exec 2>>"$cont_log_err"
             
        local r=0

        docker build \
            ${no_cache:+--no-cache} --label "bts.dockerfile.checksum=${dockerfile_sum}" \
            --build-arg "http_proxy=${http_proxy:-${HTTP_PROXY:-}}" \
            --build-arg "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
            --build-arg "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
            --build-arg "UID=$UID" \
            --build-arg "GID=$GID" \
            --build-arg "LOGNAME=$LOGNAME" \
            --build-arg "GROUPNAME=$( getent group "$(getent passwd "$LOGNAME"| awk -F':' '{print $4}')"|awk -F':' '{print $1}' )" \
            --build-arg TZ="$(cat /etc/timezone 2>/dev/null||echo 'Europe/Paris')" \
            -t bts/unit:latest \
            -f "$dockerfile" . 2>&1 || r=$?

        exec 1>&8
        exec 2>&9
        exec 8>&-
        exec 9>&-

        if ((r)); then
            echo -e "\r[Preparing environment for ${tn}... $FAILED]"
            echo "Container failed to build" >&2
            [[ -s "$cont_log" ]] && cat "$cont_log" >&2
            [[ -s "$cont_log_err" ]] && cat "$cont_log_err" >&2
        fi
        exit $r
    )
    echo -e "\r[Preparing environment for ${tcn}... $OK]"
}

_run_class_tests_in_container() {
    ((WITHIN_CONT || WITHIN_UNIT_CONT)) && echo_e "ALREADY in a cont!" && return 1
    local test_class="$1"
    local cont_name="${2:-bts/$guessed_project/$guessed_project}"
    local unit_cont="${3:-0}"
    local cont_file="${4:-Dockerfile.bts}"
    local volumes="${5:-}"
    
    ## restart bts in docker with current class
    # and WITHIN_CONT set

    # shellcheck disable=SC2068
    # shellcheck disable=SC2068
    ## -it => allow ctrl-c (disabled if CI environment is detected)
    local with_tty=1
    [[ "${CI:-}" == "true" || "${NO_TTY:-}" == 1 ]] && unset with_tty

    # create pandoc repository if missing
    \mkdir -p "$HOME/.local/shared/containers"

    local tests_to_call=()
    for test_name in ${test_classes["$test_class"]}; do
        tests_to_call+=( "${test_class}:${test_name}" )
    done

    # shellcheck disable=SC2068
    local rp; rp="$(readlink -f "$PWD")"

    ## create a volume to hosts pods
    if ! docker inspect --type=volume -f '{{ .CreatedAt }}' "bts_pods" 1>/dev/null 2>/dev/null; then
        docker volume create bts_pods 1>/dev/null 2>/dev/null
    fi
 
    ### create a volume for temporary files
    #docker volume rm bts_tmp 1>/dev/null 2>/dev/null || true
    #docker volume create bts_tmp 1>/dev/null 2>/dev/null
    #-v bts_tmp:/__bts_tmp ${volumes:+${vols[@]}} \

    ## TODO use image associated with the class
    # or, if shared, associated with the project

    local image_name privileged
    ## each unit tests in its own container
    if ((unit_cont)); then
        image_name="bts/unit"
        privileged=1
    else 
        image_name="$cont_name"
        unset privileged
    fi

    ## TODO mount BTS_VOLUMES
    local vols=()
    for vol in $(echo "${volumes:-}" | sed -re 's;,[[:space:]]; ;g'); do
        vols+=( "-v \"${vol}:${vol}\"" )
    done
    docker run --rm ${with_tty:+-it} ${privileged:+--privileged} \
        -e "http_proxy=${http_proxy:-${HTTP_PROXY:-}}" \
        -e "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
        -e "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
        -e TZ="$(cat /etc/timezone 2>/dev/null||echo 'Europe/Paris')" \
        -e WITHIN_CONT=1 \
        -e WITHIN_UNIT_CONT="${unit_cont}" \
        -e WITHIN_CONT_NAME="$cont_name" \
        -e WITHIN_CONT_FILE="$cont_file" \
        -e WITHIN_CONT_VOLUMES="$volumes" \
        -u "${UID}:${GID}" \
        -v bts_pods:"$HOME/.local/share/containers" \
        -v "${__bts_tmp_dir}:/__bts_tmp:ro" \
        -v "$rp":"$rp" \
        -w "$rp" \
            "$image_name" \
                "$bts_cmd" ${ORIG_ARGS[@]} ${tests_to_call[@]}
}

_run_class_in_container() {
    local test_class="$1"
    if cont_args="$(grep -Em1 '^[[:space:]]*@bts_(unit_)?cont($|[[:space:]]+.*$)' "$test_class")"; then
        if [[ "$cont_args" =~ ^[[:space:]]*(@bts_(unit_)?cont)[[:space:]]*(.*)$ ]]; then
            # shellcheck disable=SC2086
            if ${BASH_REMATCH[1]} ${BASH_REMATCH[3]} \
                && ((! __BTS_CONT_DISABLED)); then
                local GID="${GID:-$(id -g)}"
                local bts_cont="${BTS_CONT:-}"
                local cont_name="${BTS_CONT_NAME:-}"
                local bts_cont_can_share="${BTS_CONT_CAN_SHARE:-0}"
                local unit_cont=${BTS_UNIT_CONT:-0}
                local volumes="${BTS_VOLUMES:-}"
                local r=0

                if (( NO_CONTAINERS )); then
                    local test_class_name="${test_class##*/}"; test_class_name="${test_class_name%.sh}"
                    exec 4>&1
                    exec 5>&1
                    exec 1>/dev/null
                    exec 2>/dev/null
                    echo -ne "${INV}Running test class ${BOLD}${CYAN}${test_class_name}${RST}${in_cont:+ ${BLUEB}[in ${unit_cont:+"(unit) "}container]${RST}}" >&4
                    ((++global_disabled))
                    _manage_results "$r_disabled" "no_log"
                    exec 1>&4
                    exec 2>&5
                    exec 4>&-
                    exec 5>&-
                    return $r_disabled
                fi


                if ((unit_cont)); then
                    __build_main_image "$test_class"
                else
                    __build_cont_image "$test_class" "$bts_cont" "$cont_name" "$bts_cont_can_share"
                fi
                _run_class_tests_in_container "$test_class" "$cont_name" "$unit_cont" "$bts_cont" "$volumes" || r=$?
                ((r)) && ((++global_failures))
            elif (( ! __BTS_CONT_DISABLED )); then
                echo_e "Failed to parse @bts_cont command: $?"
                exit $r_syntax
            fi
        fi
    else
        echo_e "Failed to parse @bts_cont command"
        exit $r_syntax
    fi
    return 0
}

typeset -x BTS_TEST_LOG=
typeset -x BTS_TEST_ERR_LOG=
_run_class() {
    local test_class="$1"
    local test_sep='─'
    exec 4>&1 ## standard output
    exec 5>&2 ## error output
    local in_cont shared_cont unit_cont
    ((WITHIN_CONT || WITHIN_UNIT_CONT)) && in_cont=1 && shared_cont=1 && unset unit_cont
    ((WITHIN_UNIT_CONT)) && unset shared_cont && unit_cont=1

    local test_class_name="${test_class##*/}"; test_class_name="${test_class_name%.sh}"
    echo_o "${INV}Running test class ${BOLD}${CYAN}${test_class_name}${RST}${in_cont:+ ${BLUEB}[in ${unit_cont:+"(unit) "}container]${RST}}"

    local tests_for_class=( ${test_classes["$test_class"]} )
    local total=${#tests_for_class[@]}; local s=""; ((total>1)) && s='s'
    local pad_l=${#total}

    ((!total)) && echo_e "No test found" && return $r_ok
    echo_o "[${BLUE}Executing $total test$s${RST}]"

    failed=0
    unimplemented=0
    local class_failure=0

    for ((i=0;i<total;++i)); do
        local test_name="${tests_for_class[$i]}"

        local report_dir="${reports_base}/${test_class_name}"
        mkdir -p "$report_dir"

        ## FIXME assert log in podman will fail -- set BUGS.adoc for a fix
        log_file="${report_dir}/${test_name}.log"
        log_file_err="${report_dir}/${test_name}.err.log"
        BTS_TEST_LOG="$log_file"
        BTS_TEST_ERR_LOG="$log_file_err"
        exec 1>>"$log_file"
        exec 2>>"$log_file_err"

        local t="${test_class}:${test_name}"
        _get_test_name "$test_name"
        local ts="${__test_name}"
        local n; n=$(printf "%0${pad_l}d" "$((i + 1))")

        CURRENT_MSG="[${n}/${total}] ${BOLD}${WHITE}${ts}${RST}"
        echo_o -n "$CURRENT_MSG"
        ## call test in an isolated environment (somehow)
        local r=0
        if ((WITHIN_UNIT_CONT)); then
            _run_raw_cont "$t" || r=$?
        else
            #"$bts_cmd" --raw "$t" || r=$?
            _run_raw "$t" || r=$?
        fi
        ## clear captured_logs
        [[ -n "$BTS_CAPTURED_OUT" ]] && { \rm -f "$BTS_CAPTURED_OUT"; unset BTS_CAPTURED_OUT; }
        [[ -n "$BTS_CAPTURED_ERR" ]] && { \rm -f "$BTS_CAPTURED_ERR"; unset BTS_CAPTURED_ERR; }
        
        _manage_results "$r" "${report_dir}/${test_name}" || r=$?
        ((r)) && class_failure=1
        ((r>1)) && break
    done
    ((class_failure)) && ((++global_failures))

    exec 1>&4
    exec 2>&5
    exec 4>&-
    exec 5>&-

    set +e
    local report_msg=""
    report_msg="\u21d2"
    report_msg+=" [$( ((failed)) && echo -n "$RED" || echo -n "$GREEN" )"
    report_msg+="$((total - failed))$( ((failed)) && echo -n "$RST" )/$total${RST}]"
    report_msg+=" ($( ((failed)) && echo -n "$RED" )$failed failure$( ((failed>1)) && echo -n "s" )"
    report_msg+="$( ((unimplemented)) && echo -n ", $unimplemented being unimplemented test$( ((unimplemented>1)) && echo -n "s" )" ))"
    set -e

    ## display class results
    __box_up --no-border -w 2 \
        "$report_msg"
}

# shellcheck disable=SC2120
_run_batch() {
    ((DEBUG>1)) && set -x
    _get_called_tests "$@"

    ## LIST_ONLY
    if ((LIST_ONLY)); then
        for test_class in "${!test_classes[@]}"; do
            local tc="${test_class##*/}"; tc="${tc%.sh}"
            #echo "t: '$t' => ${test_classes["$t"]}"
            echo -e "${INV}Test class ${BOLD}${CYAN}$tc${RST}"
            local tests_to_run=( ${test_classes["$test_class"]} )
            local pad=${#tests_to_run[*]}; pad=${#pad}
            local i=0
            for test_name in "${tests_to_run[@]}"; do
                _get_test_name "$test_name"
                local tn="${__test_name}"
                printf "${BOLD}${BLUE}[%0${pad}d] ${BOLD}${CYAN}%s${RST}\n" $((++i)) "$tn"
            done
        done
        return 0
    fi

    ## create bts's tmp. dir.
    mkdir -p "${__bts_tmp_dir}"

    ## FIXME this should go in _prepare_class
    ## copy specific environment into context, just one, by order or preference
    for b_env in .env.bts .bts.env bts.env; do
        if [[ -f "$b_env" ]]; then
            \cp "$b_env" "${__bts_tmp_dir}/.env.bts"
            break
        elif [[ -f "/__bts_tmp/$b_env" ]]; then
            \cp "/__bts_tmp/$b_env" "${__bts_tmp_dir}/.env.bts"
            break
        fi
    done

    ## pre-process tests
    for test_class in "${!test_classes[@]}"; do
        _prepare_class "$test_class"
    done

    ## actually run tests
    local failed=0
    local missing=0
    local unimplemented=0
    local disabled=0
    local log_file log_file_err
    local ordered_test_classes=()
    while read -r tc; do
        ordered_test_classes+=( "$tc" )
    done <<<"$(echo "${!test_classes[@]}" | tr ' ' $'\n' | sort -u)"
    local total_classes=${#ordered_test_classes[@]}
    
    local global_failures=0
    local global_disabled=0
    ## TODO send these to ./report/test/...
    for ((k=0;k<total_classes;++k)); do
        local test_class="${ordered_test_classes[$k]}"
        if (( ! WITHIN_CONT )) && __wants_container "$test_class"; then
            _run_class_in_container "$test_class" || continue
        else
            _run_class  "$test_class" || continue
        fi
    done

    ## don't display summary for only one class
    if ((total_classes == 1)); then
        ((global_failures)) && exit 1
        exit 0
    fi

    total_classes=$(( total_classes - global_disabled ))
    ## display global results
    ## just a bit of space
    #echo

    ## border style to apply to box, depending on status
    local border_style
    # compute pad to align digits
    local d_pad=${#total_classes}
    # compute results
    local total_success; total_success="$( printf "%${d_pad}d" "$(( total_classes - global_failures ))" )"

    ## box's title
    local header_msg="${INV} Global Results ${RST}"
    ## message to display
    set +e
    local status_msg
    status_msg="\u21d2"
    status_msg+=" [$( ((global_failures)) && echo -n "$RED" || echo -n "$GREEN" )"
    status_msg+="${total_success}$( ((global_failures)) && echo -n "$RST" )"
    status_msg+="/${total_classes}${RST}]"
    status_msg+=" ($( ((global_failures)) && echo -ne "${INV}${RED}" )$global_failures failure$( ((global_failures>1)) && echo -n 's' )$( ((global_disabled>1)) && echo ", ${YELLOW}$global_disabled disabled${RST}" )${RST})"
    set -e

    ((global_failures)) && border_style='-e'
    __box_up \
        ${border_style:---rounded} \
        -t "$header_msg" \
        "$status_msg"

    ((global_failures)) && exit 1
    exit 0
}

ARGS=()
TEST_DIR=tests
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0;;
        -P|--no-pretty-name) PRETTY_NAME=0;;
        -vv*|--very-verbose) SHOW_OUTPUT=1; VERBOSE=1;;
        -v|--verbose) SHOW_FAILED=1; VERBOSE=1;;
        -C|--no-color) NO_COLORS=1;;
        -c|--color) NO_COLORS=0;;
        -dd|--extra-debug) DEBUG=2;;
        -d|--debug) DEBUG=1;;
        -D|--DEBUG) DEBUG_BTS=1;;
        -q|--quiet) QUIET=1; SHOW_FAILED=0; VERBOSE=0;;
        -qq|--very-quiet|-s|--silent) QUIET=1; SHOW_FAILED=0; SHOW_OUTPUT=0;;
        -l|--list|--list-tests) LIST_ONLY=1;;
        -t|--tests-dir) TEST_DIR="$2"; shift;;
        -r|--project-root) PROJECT_ROOT="$2"; shift;;
        -f|--first-fail) FIRST_FAIL=1;;
        --clean) CLEAN_UP=1;;
        --raw) RAW_RUN=1;;
        --no-containers) NO_CONTAINERS=1;;
        -*) echo "Unknown argument: '$1'"; usage; exit 1;;
        *) ARGS+=( "$1" )
            shift
            continue
            ;;
    esac
    ORIG_ARGS+=( "$1" )
    shift
done

! ((NO_COLORS)) && _set_colors
set -- "${ARGS[@]}"

## clean up env and exit
if (( CLEAN_UP )); then
    ## remove all containers: docker volume rm bts_pods, bts/unit
    docker rmi bts/unit 1>/dev/null 2>/dev/null||true
    docker volume rm bts_pods 1>/dev/null 2>/dev/null||true
    ## remove temporary files: /tmp/bts
    \rm -rf /tmp/__bts_tmp_dir.__*  ||true
    ## remove reports, if within a projects: detect in tests/ exists and, if so, remove ./reports
    if [[ -d "${TEST_DIR:-}" && -d reports ]]; then
        \rm -rf reports || true
    fi
    exit 0
fi

## no tests found
! [[ -d "$TEST_DIR" ]] && echo "Nothing to test" && exit 0

export __BTS_TEST_DIR="$TEST_DIR"
export PROJECT_ROOT="$( readlink -f "${PROJECT_ROOT:-.}" )"

## clean up before processing
if ! (( WITHIN_CONT )) && ! [[ -e /__bts_tmp ]]; then
    echo "Cleaning previous run..."
    \rm -rf "${__bts_tmp_dir}"
    \rm -rf "$reports_base"
fi

if ((RAW_RUN)); then
    _run_raw "$1"
else
    test_list="${@:-$here/$TEST_DIR/[0-9]*.sh}"
    _run_batch
fi
