#!/usr/bin/env bash
# vim: ts=4 sts=4 sw=4 expandtab

set -o pipefail
set -u

## keep relative, because readlink would resolve with an unreachable path if bts.sh is a symlink
# well relative whould work very well either, would it? so, we don't care.
typeset bts_cmd
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

## try to use bash's 4.4+ Parameters Transformations to keep empty arguments by quoting them
bts_bash_tr=0
(( "${BASH_VERSINFO[0]:-0}${BASH_VERSINFO[1]:-0}" > 43 )) && bts_bash_tr=1;
export bts_bash_tr

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
    -r|--project-root <dir> project's base root (default: .)
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
    assert [ok|true|ko|false|equals|same|empty] <expression>
        true     assert evaluation is true
        false    assert evaluation if false
        equals   assert left string equals expected right string
        empty    assert result output is empty
        same     assert left string or file contents equals expected right string or file contents
        same~    assert left string or unordered file contents equals expected right string or unordered file contents
        samecol  compare same column from two files; column number and separator can be passed after files (default: column 1, comma (;) as separator)
        samecol~ compare same column from two unordered files; column number and separator can be passed after files (default: column 1, comma (;) as separator)
        exists   assert contents exist
        err      assert last error log contains expression (requires @capture_logs)
    asset [-n] <asset[.gz|bz2]> [dest-dir|dest-file]
        try its best to find file in 'TEST_DIR/assets/[test_name]...' and send it to destination or stdout
        -n       pass full path to ressource, instead of contents
    @should_fail <expression>
                assert next evaluation fails as expected
    @capture_log capture logs (required by assert err)

Utils (class)
    @load                       load a file relative to test dir; useful to load common tests or functions, for instance
    mock_funcs/__mock_funcs     load mockup functions; syntax: mockup_function[:alias]; ex., __mock_funcs='__crontab:crontab'
                                this is mainly usefull when loading an environment before calling another shell command than bash, for eg., ksh

Other
    .btsignore  bts will ignore _tests_ declared in this file -- one per line, no glob or regex; reminder: bts ignores anything not matching [0-9]*.sh anyway

Debug/trace:
    trace    display message in output (logged)
    dbg      display a dbg message in output (logged)
EOU
}

exp_vars=()
exp_cmds=()
exp_utils=()

## ----------------------- lib
declare RST BLINK INV BLUE RED GREEN YELLOW MAGENTA WHITE CYAN
diff_=$(which diff) || { fatal "Can't find 'diff' command!"; exit 1; }
bts_diff() {
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
FATAL=FATAL
TODO=TODO
INTERRUPTED=INTERRUPTED
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
exp_vars+=( r_ok r_fail r_fatal r_warn r_todo r_break )

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
    ((!QUIET && DEBUG)) && echo -e "${INV}${BOLD}[DBG]${RST} ${BOLD}${WHITE}$@${RST}" >&1
    return 0
}
DBG() {
    ((DEBUG_BTS)) && echo -e "${INV}${BOLD}${BLUE}[BTS]${RST} ${BOLD}${WHITE}$@${RST}" >&1
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
    [[ "$1" == -n ]] && filename_only=1 && shift
    local _a="${1:-Missing asset name}"
    local d="${2:-}"
    local a
    if [[ -e "$TEST_DIR/assets/${_a}" ]]; then
        a="$TEST_DIR/assets/${_a}"
    else
        a=$(find "$TEST_DIR/assets/${__bts_this}" -maxdepth 1 -regextype egrep \
            -regex "$TEST_DIR/assets/${__bts_this}/${t}[_.]+${_a}(.gz|.bz2)?" \
            -or \
            -regex "$TEST_DIR/assets/${__bts_this}/${_a}(.gz|.bz2)?" 2>/dev/null | grep '.' \
            || find "$TEST_DIR/assets" -maxdepth 1 -regextype egrep \
            -regex "$TEST_DIR/assets/${t}[_]*${_a}(.gz|.bz2)?" \
            -or \
            -regex "$TEST_DIR/assets/${_a}(.gz|.bz2)?" 2>/dev/null | grep '.'
            ) || {
                echo "Can't find asset '$_a' in '$TEST_DIR/assets/${__bts_this}' nor '$TEST_DIR/assets'" >&2
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
    local args="${@:-}"
    local abs_path="$(readlink -m "${__BTS_TEST_DIR}/$f")"
    set -- "$args"
    source "$abs_path"
}

@todo() {
    echo "unimplemented: ${FUNCNAME[1]}"
    return $r_todo
}


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

    local r=0
    ## capture and re-throw for bts
    ! eval "$(printf "%q " "${args[@]}")" 1> >(tee "$out_log") 2> >(tee "$err_log" >&2) && r=1
    #[[ -s "$out_log" ]] && cat "$out_log" >&1
    #[[ -s "$err_log" ]] && cat "$err_log" >&2
    return $r
}
BTS_CONT=0
BTS_CONT_NAME=
BTS_CONT_CAN_SHARE=0
WITHIN_CONT=${WITHIN_CONT:-0}
SHARED_CONT=${SHARED_CONT:-0}
## @bts_cont [enabled:1 (default)|disabled:0|Dockerfile to use (defaults: Dockerfile.bts)] [container_name]
@bts_cont() {
    local cont_state="${1:-}"
    local cont_name="${2:-}"; cont_name="${cont_name,,}"
    if [[ "${cont_state,,}" == false || "$cont_state" == 0 ]]; then return 1; fi
    [[ -f "$cont_state" ]] && BTS_CONT="$cont_state" || BTS_CONT="Dockerfile.bts"
    [[ "$BTS_CONT" == "Dockerfile.bts" && -z "$cont_name" ]] && BTS_CONT_CAN_SHARE=1
    BTS_CONT_NAME="${cont_name:+bts/${cont_name#bts/}}"
    return 0
}
exp_utils+=( @load @bts_cont @escape_parameters )

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
    local r
    SHOULD=1
    SHOULD_FAIL=1
    #( trap - ERR; (! eval "$@") ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
    ## fix: empty parameters are discarded
    if (($#>1)); then
        if (( bts_bash_tr )); then
            ( trap - ERR; (! eval "${args[@]@Q}") ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
        else
            ( trap - ERR; (! eval "$(printf "%q " "${args[@]}")" ) ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
        fi
    else
        ( trap - ERR; (! eval "${args[@]}") ) && { SHOULD=0; SHOULD_FAIL=0; } && return $r_ok
    fi
    fail
}

assert() {
    local has_err=""
has_err=$(
    local NOT=0
    local sf=${f##*/}
    [[ "$1" == NOT || "$1" == not ]] && NOT=1 && shift
    local _not=$( ((NOT)) && echo ' NOT' )
    local is_not=$( ((NOT)) && echo 'NOT ' )
    local a="$1"; shift
    local r
    local a_cap="${a^^}"
    case "${a_cap}" in
        OK|TRUE|KO|FALSE|EQUALS|EMPTY|MATCH|SAME|SAME~|EXISTS|FILE~|FILE|DIR|DIR~|SAMECOL|SAMECOL~|ERR|LOG|WARN)
            a="${a_cap}"
            ;;
        *) echo "unknown assertion '$a' (${sf}:${FUNCNAME[1]}:${BASH_LINENO[0]})"; return $r_fail;;
    esac
    set -- "$@"
    [[ -z "${@+z}" ]] && echo_c SYNTAX "Missing evaluation!" && exit 1
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
                        cmp="$@"; unset exp; (eval "$@";) && r=0 || r=1
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
                        cmp="$@"; unset exp; (eval "$@";) && r=0 || r=1
                    fi
            esac
            [[ "$a" == KO ]] && r=$((!r))
            ;;
        EQUALS) [[ "$cmp" == "$exp" ]] && r=0 || r=1;;
        FILE~|DIR~) local dn="$(dirname "$cmp")"; find "$dn" -maxdepth 1 -regex "$dn/$(basename "$cmp")" 2>/dev/null| grep -q '.' && r=0 || r=1;;
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

        ERR)
            if ! [[ -s "${BTS_CAPTURED_ERR:-}" ]]; then
                [[ -n "$cmp" ]] && r=1 || r=0
            else
                if ! (grep -qF "$cmp" "$BTS_CAPTURED_ERR" || grep -qE "$cmp" "$BTS_CAPTURED_ERR"); then
                    exp="$(cat "$BTS_CAPTURED_ERR")"
                    r=1
                else
                    r=0
                fi
            fi
            ;;
        LOG)
            if ! [[ -s "${BTS_CAPTURED_OUT:-}" ]]; then
                [[ -n "$cmp" ]] && r=1 || r=0
            else
                if ! (grep -qF "$cmp" "$BTS_CAPTURED_OUT" || grep -qE "$cmp" "$BTS_CAPTURED_OUT"); then
                    exp="$(cat "$BTS_CAPTURED_OUT")"
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

        local c="$( sed -n "${line}p" "$f" | sed -e 's/^[\t ]*\(.*\)$/\1/g')"
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
    if [[ -n "$has_err" ]]; then echo "$has_err"; fi
    return 1
}
}

## ------ params

LIST_ONLY=0
INTERACTIVE=0
SHOW_OUTPUT=0
SHOW_FAILED=1
NO_COLORS=0
VERBOSE=0

oldIFS=$IFS
home="$( dirname "$(readlink -f "$0")" )"
here="$(readlink -f "$PWD")"
guessed_project="$(basename "$here")"
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
    $(export_utils)
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

__wants_container() {
    grep -q '^[[:space:]]*@bts_cont' "$1"
}
_run_in_docker() {
    (( WITHIN_CONT )) && return 1

    local f="${1:?Missing test class}"
    local t="${2:-}"
    local sf="${f##*/}"

    ## execute in container if asked
    if cont_args=$(grep '^[[:space:]]*@bts_cont' "$f"); then
        if [[ "$cont_args" =~ ^[[:space:]]*@bts_cont[[:space:]]*(.*)$ ]]; then
            # shellcheck disable=SC2086
            if @bts_cont ${BASH_REMATCH[1]}; then
                local GID="${GID:-$(id -g)}"
                local bts_cont="${BTS_CONT:-}"
                local cont_name="${BTS_CONT_NAME:-}"
                local bts_cont_can_share="${BTS_CONT_CAN_SHARE:-0}"

                ## reset to default values
                BTS_CONT=0
                BTS_CONT_NAME=
                BTS_CONT_CAN_SHARE=0
                
                local cont_tag="latest"
                if [[ -z "$cont_name" ]]; then
                    local cn="${sf%.*}"; cn="${cn,,}"
                    cont_name="bts/${guessed_project,,}"
                    cont_tag="${cn//:/_}"
                    #if (( bts_cont_can_share )); then
                    #    cont_name="bts/$guessed_project"
                    #    cont_tag="${cn//:/_}"
                    #else
                    #    cont_name="bts/$guessed_project/${cn//:/_}"
                    #    cont_tag="latest"
                    #fi
                fi

                #echo "cont name: '$cont_name', sf: '$sf' => '${sf//:/_}' ('$f')"
                local created_at cont_build_tag
                (( bts_cont_can_share )) && {
                    DBG "(will use shared image ${cont_name}:latest)"
                    cont_build_tag='latest' 
                } || cont_build_tag="$cont_tag"
                local was_rebuilt=0
                ## rebuild main image
                if ! created_at="$(docker inspect --type=image -f '{{ .Created }}' "${cont_name}:${cont_build_tag}" 2>/dev/null)" \
                    || (( $(date --date "$(stat -c '%y' Dockerfile.bts)" +"%s") > $(date --date "$created_at" +"%s") ))
                then
                    was_rebuilt=1
                    ## create a tag instead of rebuilding image for tests sharing the same Dockerfile (problem: how to find out this is the same Dockerfile?...)
                    echo "Building image: '${cont_name}:${cont_build_tag}' (from '$bts_cont')"
                    ## some discrepency between existing container and wanted one, probably coming from a more recent -- force rebuild
                    [[ -n "$created_at" ]] && no_cache=1
                    ## (re)build container if needed, execute within
                    docker build \
                        ${no_cache:+--no-cache} --build-arg "http_proxy=${http_proxy:-${HTTP_PROXY:-}}" \
                        --build-arg "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
                        --build-arg "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
                        --build-arg "UID=$UID" \
                        --build-arg "GID=$GID" \
                        --build-arg TZ="$(cat /etc/timezone 2>/dev/null||echo 'Europe/Paris')" \
                        -f "$bts_cont" \
                        -t "${cont_name}:${cont_build_tag}" . 2>&1 || {
                        return 1
                    }
                fi
                ## update tag if shared image
                if ((bts_cont_can_share)); then
                    if (( was_rebuilt )) || ! docker inspect --type=image "${cont_name}:${cont_tag}" 1>/dev/null 2>/dev/null; then
                        docker rmi "${cont_name}:${cont_tag}" 1>/dev/null 2>/dev/null || true
                        docker tag "${cont_name}:latest" "${cont_name}:${cont_tag}"
                    fi
                fi

                # shellcheck disable=SC2016
                DBG "Starting test '$f' within container ${ORIG_ARGS:+(with options: '${ORIG_ARGS[*]})'}"
                ## restart within container
                local rp; rp=$(readlink -f "$PWD")
                local rp_tests="${rp}/${TEST_DIR}"

                # shellcheck disable=SC2068
                ## -it => allow ctrl-c (disabled if CI environment is detected)
                local with_tty=1
                [[ "${CI:-}" == "true" || "${NO_TTY:-}" == 1 ]] && unset with_tty

                docker run --rm \
                    ${with_tty:+-it} -e "http_proxy=${http_proxy:-${HTTP_PROXY:-}}" \
                    -e "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
                    -e "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
                    -e WITHIN_CONT=1 \
                    -e SHARED_CONT="${bts_cont_can_share:-0}" \
                    -v "$rp":"$rp" \
                    -v "$rp_tests":"$rp_tests":ro \
                    -w "$rp" \
                    -u "${UID}:$(id -g)" \
                    "${cont_name}:${cont_tag}" "$bts_cmd" ${ORIG_ARGS[@]} "$f${t:+:$t}"
                return $?
            fi
        fi
    fi
    return 1
}

typeset -x BOX_WIDTH=36
function __box_up {
    local title=""
    local colour=""
    local box_msg=()
    local box_width=${BOX_WIDTH:-35}
    local rounded=0
    local squared=0
    local thick=0
    _set_border() {
        case "$1" in
            rounded) rounded=1; thick=0; squared=0;;
            squared) rounded=0; thick=0; squared=1;;
            thick) rounded=0; thick=1; squared=0;;
            *) rounded=1; thick=0; squared=0;;
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
            -e|--error) _set_border "thick"; colour="${colour:-$RED}";;
            *) box_msg+=( "$1" );;
        esac
        shift
    done
    
    ## default border style
    ! (( rounded || squared || thick )) && rounded=1

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

    total=${#l_tests[@]}; local s=""; ((total>1)) && s='s'
    pad_l=${#total}

    ((!total)) && echo "No test found" && return $r_ok
    echo "Executing $total test$s"
    echo
    local n=0; local nn=0
    local _preset_executed=0
    local _end=$(( ${#l_tests[@]} ))
    local _cur=0
    local _is_last=0

    (
        _trap_main_exit() {
            local retval=$?
            \rm -f "$main_tmp_sh" "${main_tmp_sh}.log"
            [[ -n "${BTS_CAPTURED_ERR:-}" ]] && \rm -f "$BTS_CAPTURED_ERR"
            [[ -n "${BTS_CAPTURED_OUT:-}" ]] && \rm -f "$BTS_CAPTURED_OUT"
            exit $retval
        }
        trap '_trap_main_exit' EXIT
        _trap_main_break() {
            exit $r_break
        }
        trap '_trap_main_break' SIGINT
        trap '_trap_main_break' SIGTERM

        failed=0
        unimplemented=0
        ## prepare tests
        __bts_this="$(basename "$( readlink -f "$f" )")"; __bts_this="${__bts_this%.sh}"
        #main_tmp_sh="$TEST_DIR/.${__bts_this}_bts.sh"
        main_tmp_sh="/tmp/${__bts_this}_bts.sh"
        cat "$f" > "$main_tmp_sh"
        sed -ri 's;%\{this\};'"${__bts_this}"';g' "$main_tmp_sh"
        sed -ri 's;%\{assets\};'"${TEST_DIR}/assets/${__bts_this}"';g' "$main_tmp_sh"
        sed -ri 's;%\{root_dir\};'"$(dirname "$(readlink -f "${TEST_DIR}")")"';g' "$main_tmp_sh"
        sed -ri 's;%\{assets_dir\};'"$(readlink -f "${TEST_DIR}/assets")"';g' "$main_tmp_sh"

        ## source main script, for preset & reset
        source "$main_tmp_sh"
        # execute preset
        [[ -n "$preset" ]] && {
            exec 8>&1
            exec 9>&2
            local pre_log
            pre_log="${main_tmp_sh}.log"
            __preset_res=0
            if ((VERBOSE)); then
                "$preset" > >(tee "$pre_log" >&9) 2>&1 || __preset_res=1
            else
                "$preset" > "$pre_log" 2>&1 || __preset_res=1
            fi
            exec 1>&8
            exec 2>&9
            if ((__preset_res)) || grep -q "command not found" "$pre_log" 2>/dev/null; then
                __preset_res=1
                echo "Preset failed to execute:" >&2
                if ((!VERBOSE)); then
                    cat "$pre_log" >&2
                fi
            fi
            \rm -f "$pre_log"
            ((__preset_res)) && exit $r_fatal
        }

        r=0
        ## execute tests
        local d_pad=${#total}
        # shellcheck disable=SC2068
        for t in ${l_tests[@]}; do
            ((++_cur >= _end)) && _is_last=1
            ((++n)); nn=$(printf "%02d" "$n")
            local ts=${t##*test_}; ts=${ts//__/: }; ts=${ts//_/ }
            local log_file="${results}/${nn}.${t}.log"
            local log_file_err="${results}/${nn}.${t}.err.log"
            ((SHOW_OUTPUT && n>1)) || (( SHOW_FAILED && prev_failed)) && echo
            (
                exec 8>&1
                exec 9>&2
                exec 1>>"$log_file"
                exec 2>>"$log_file_err"

                echo "--- [$t] ----"

                set -o pipefail
                set -eE
                set -o functrace
                _trap_exit() {
                    local retval=$?
                    \rm -f "$tmp_sh"
                    [[ -n "${BTS_CAPTURED_ERR:-}" ]] && \rm -f "$BTS_CAPTURED_ERR"
                    [[ -n "${BTS_CAPTURED_OUT:-}" ]] && \rm -f "$BTS_CAPTURED_OUT"
                    exit $retval
                }
                trap '_trap_exit' EXIT
                _trap_break() {
                    exit $r_break
                }
                trap '_trap_break' SIGINT
                trap '_trap_break' SIGTERM

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

                    ## teardown anyway
                    [[ -n "$teardown" ]] && {
                        $teardown || { echo "WARN: failed to execute '$teardown'!"; ((!retval)) && retval=$r_warn; }
                    }

                    echo "--- [$( ((retval)) && echo $FAILED || echo $OK)]: $t --------"
                    echo
                    local err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n');
                    local trc="(--> [${FUNCNAME[*]}, ${BASH_LINENO[*]}])"
                    local t=( "Failed at ${sf}:${func}:${fline}" ": ${err_line:-$BASH_COMMAND}" "$trc" "TRAP TO RETURN $retval" )
                    local max=0; for l in "${t[@]}"; do s=${#l}; (( s > max )) && max=$s; done; ((max+=4))
                    echo -e "${BOLD}${BLUE}-- traces ------------${RST}"
                    for l in "${t[@]}"; do
                        printf "${YELLOWB}    ${BLACK}%-${max}s${RST}\n" "$l"
                    done

                    exec 1>&8
                    exec 2>&9
                    exec 7>&-

                    exit $retval
                }
                trap '_trap_err' ERR
                
                command_not_found_handle() {
                    local line=${BASH_LINENO[0]}
                    local err_line=$(sed -n ${line}p "$f"|xargs|tr -d $'\n')
                    echo -e "FATAL: command not found: ${sf}:${FUNCNAME[1]}:${BASH_LINENO[0]}:\n -> $err_line"
                    exit $r_cnf ## useless, handle won't pass exit code
                }

                tmp_sh="$main_tmp_sh.partial"
                sed -re 's;%\{this\};'"${__bts_this}"';g;s;%\{this_test\};'"${t}"';g' "$main_tmp_sh" > "$tmp_sh"
                eval export ${t##*test_}=1
                eval export ${t}=1
                if [[ "${t#*__}" != "$t" ]]; then eval export ${t#*__}=1; fi
                source "$tmp_sh"
                \rm -f "$tmp_sh"

                [[ -n "$setup" ]] && { $setup || exit $r_fatal2; }

                local _nn; _nn="$( printf "%${d_pad}d" "$n" )"
                echo -en "[${_nn}/${total}] ${BOLD}${WHITE}${ts}${RST}" >&8
                if ((VERBOSE)); then
                    echo >&9
                    $t 1> >(tee -a "$log_file" >&9) 2> >(tee -a "$log_file_err" >&9); rr=$?
                else
                    $t; rr=$?
                fi

                [[ -n "$teardown" ]] && {
                    $teardown || { echo "WARN: failed to execute '$teardown'!"; ((!rr)) && rr=$r_warn; }
                }
                echo "--- [$( ((rr)) && echo $FAILED || echo $OK)]: $t --------"
                exec 1>&8
                exec 2>&9
                exec 7>&-
                exit $rr
            ); r=$?

            ## check cnf
            grep -iq 'FATAL: command not found' "$log_file" "$log_file_err" && r=$r_cnf
            ((r)) && prev_failed=1 || prev_failed=0

            _no_forced_log=0
            case $r in
                $r_break) echo_c FATAL " -> [$INTERRUPTED]"
                    _no_forced_log=1;
                    exit $r_break
                    ;;
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

                ## FIXME: preset is not here anymore, refactor
                $r_fatal|$r_fatal2) echo_c FATAL " [FATAL] Failed to execute $( ((r==r_fatal)) && echo 'preset' || echo 'setup')"
                    cat "$log_file"
                    cat "$log_file_err"
                    break
                    #return $r_fatal
                    ;;
                $r_cnf) echo_c FATAL " [FATAL] Command not found. Aborting."
                    cat "$log_file"
                    cat "$log_file_err"
                    break
                    #return $r_fatal
                    ;;

                $r_warn) echo_c WARN " [WARNING] Failed to execute some environmental method"
                    ;;

                *) echo " -> [UNK STATE:$r]"
                    ;;
            esac
            if ((!VERBOSE)); then
                ((r==$r_warn || r==$r_fatal || r==$r_cnf || SHOW_OUTPUT)) && cat "$log_file" "$log_file_err" || {
                    ((r && SHOW_FAILED && !_no_forced_log )) && cat "$log_file" "$log_file_err"
                }
            fi
        done

        ## reset, if found
        [[ -n "$reset" ]] && {
            $reset || { echo "WARN: failed to execute '$reset'!"; }
        }

        echo
        echo -e "-> [$((total-failed))/$total] ($( ((failed)) && echo -ne "$RED" )$failed failure$(((failed>1)) && echo s)$(((unimplemented)) && echo ", $unimplemented being unimplemented test$(((unimplemented>1))&& echo s)"))"
        ((failed)) && exit 1 || exit 0
    )
}

## ----- main

run() {
    _run_break() {
        exit $r_break
    }
    trap '_run_break' SIGINT
    trap '_run_break' SIGTERM
    local f
    \rm -rf "$results_base"
    mkdir -p "$results_base"
    local state=0
    local results
    local f
    ## load local env
    if [[ -f 'bts.env' ]]; then
        eval $(while read -r l; do
            [[ "$l" =~ ^# || ! "$l" =~ = ]] && continue
            ! [[ "$l" =~ ^[\t\ ]*export[\t\ ]+ ]] && l="export $l"
            echo $l
        done <bts.env)
    fi
    local tests_to_run=()
    local tests_to_ignore=( $( [[ -f "$TEST_DIR/.btsignore" ]] && cat "$TEST_DIR/.btsignore" || echo "" ) )
    local tests_to_ignore="${tests_to_ignore[@]}"
    for f in ${test_list}; do
        [[ " $tests_to_ignore " =~ \ ${f##*/}\  ]] && continue
        tests_to_run+=( "$f" )
    done

    local failed=0
    for f in ${tests_to_run[@]}; do
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
            for k in "${!tests_i[@]}"; do
                local kk="$k"
                #local kk=${k//__/: }; kk=${kk//_/ }
                int_tests+=( "$k" )
                printf "${BOLD}${BLUE}[%02d] ${BOLD}${CYAN}%s${RST}\n" $((++i)) "$kk"
            done
            continue
        }

        #local total=0
        #local failed=0
        local fr=${ff##*/}
        results="$results_base/${fr%.*}"; mkdir -p "$results"
        if (( ! WITHIN_CONT )) && __wants_container "$ff"; then
            DBG "(running ${BOLD}${CYAN}$fr${RST} in ${INV}container${RST})"
            _run_in_docker "$ff" "$t"
        else
            local in_cont shared_cont
            ((WITHIN_CONT)) && in_cont=1 && (( SHARED_CONT )) && shared_cont=1
            echo -e "${INV}Running test class ${BOLD}${CYAN}$fr${RST}${in_cont:+ ${BLUEB}[in ${shared_cont:+"(shared) "}container]${RST}}"
            _run_tests "$ff" "$t"
        fi
        local r=$?
        (( r )) && state=1 && ((++failed))
        (( r == r_fatal )) && break
    done
    
    ## display total if many classes were run
    if ((!WITHIN_CONT && ${#tests_to_run[@]} > 1)); then
        ## just a bit of space
        echo

        ## total number of classes run
        local total=${#tests_to_run[@]}
        ## box's title
        local header_msg="${INV} Global Results ${RST}"
        local border_style
        local d_pad=${#total}
        local total_success; total_success="$( printf "%${d_pad}d" "$(( total - failed ))" )"
        ((failed)) && border_style='-e'
        __box_up \
            ${border_style:---rounded} \
            -t "$header_msg" \
            "-> [$total_success/$total] ($( ((failed)) && echo -ne "${INV}${RED}")$failed failure$( ((failed>1)) && echo -n 's')${RST})"

    fi

    return $state
}

ARGS=()
TEST_DIR=tests
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0;;
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
        #-i|--interactive) LIST_ONLY=1; INTERACTIVE=1;;
        *) ARGS+=( "$1" )
            shift
            continue
            ;;
    esac
    ORIG_ARGS+=( "$1" )
    shift
done
!((NO_COLORS)) && _set_colors
set -- "${ARGS[@]}"
## no tests found
! [[ -d "$TEST_DIR" ]] && echo "Nothing to test" && exit 0

export __BTS_TEST_DIR="$TEST_DIR"
export PROJECT_ROOT="$( readlink -f "${PROJECT_ROOT:-.}" )"

test_list="${@:-$here/$TEST_DIR/[0-9]*.sh}"
run
