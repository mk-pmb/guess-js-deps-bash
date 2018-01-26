#!/bin/bash
# -*- coding: utf-8, tab-width: 2 -*-
SELFPATH="$(readlink -m "$BASH_SOURCE"/..)"; INVOKED_AS="$(basename "$0" .sh)"

source "$SELFPATH"/lib_dict_util.sh --lib || exit $?


function guess_js_deps () {
  export LANG{,UAGE}=en_US.UTF-8  # make error messages search engine-friendly
  #cd "$SELFPATH" || return $?

  local DBGLV="${DEBUGLEVEL:-0}"
  local COLORIZE_DIFF="$(can_haz_cmd colordiff)"
  local MANI_BFN='package.json'
  local KNOWN_DEP_TYPES=( dep devDep )

  local RUNMODE="$1"; shift
  local OUTPUT_MODE=( fail 'Unsupported output mode. This is a bug.' )
  case "$RUNMODE" in
    as-json ) OUTPUT_MODE=( dump_deps_as_json );;
    '' | \
    cmp )     OUTPUT_MODE=( compare_deps_as_json "$COLORIZE_DIFF" );;
    upd )     OUTPUT_MODE=( update_manifest );;
    tabulate-found )  OUTPUT_MODE=( 'fmt://tsv' );;
    scan-known )      scan_manifest_deps; return $?;;
    tabulate-known )  tabulate_manifest_deps; return $?;;
    scan-imports )   find_imports_in_files "$@"; return $?;;
    --func ) "$@"; return $?;;
    * ) fail "unsupported runmode: $RUNMODE"; return 2;;
  esac

  local CWD_PKG_NAME="$(guess_cwd_pkg_name)"
  progress 'I: Searching for JavaScript files: '
  local IMPORTS=(
    -type f
    '(' -name '*.js'
        -o -name '*.mjs'
        -o -name '*.jsm'
        ')'
    )
  readarray -t IMPORTS < <(fastfind "${IMPORTS[@]}")
  progress "found ${#IMPORTS[@]}"
  [ -n "${IMPORTS[0]}" ] || return 3$(
    fail "Unable to find any import()s/imports in package: $CWD_PKG_NAME")

  progress 'I: Searching for require()s/imports in those files: '
  readarray -t IMPORTS < <(
    find_imports_in_files --guess-types "${IMPORTS[@]}"
    )
  if [ "${OUTPUT_MODE[0]}" == 'fmt://tsv' ]; then
    printf '%s\n' "${IMPORTS[@]}"
    return 0
  fi
  local -A DEPS_BY_TYPE
  dict_split_tsv_by_1st_column DEPS_BY_TYPE "${IMPORTS[@]}"
  progress "found $(<<<"${DEPS_BY_TYPE[dep]}" grep . | wc -l) deps" \
    "and $(<<<"${DEPS_BY_TYPE[devDep]}" grep . | wc -l) devDeps."
  [ "$DBGLV" -ge 2 ] && dump_dict DEPS_BY_TYPE | sed -re '
    s~^\S+~Found: &~;s~^~D: ~'

  "${OUTPUT_MODE[@]}"
  return $?
}


function can_haz_cmd () {
  local CMD=
  for CMD in "$@"; do
    </dev/null "$CMD" &>/dev/null || continue
    echo "$CMD"
    return 0
  done
  return 2
}


function dump_deps_as_json () {
  local DEP_TYPE=
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    printf '"%sendencies": ' "$DEP_TYPE"
    <<<"${DEPS_BY_TYPE[$DEP_TYPE]}" sed -re '
      1{${s~^$~{},~}}
      /\t/{
        s~^~  "~
        s~\t~": "^~
        s~$~",~
        1s~^~{\n~
        $s~,$~\n},~
      }
      '
  done
}


function compare_deps_as_json () {
  local OUTPUT_FILTER=( "$@" )
  [ -n "${OUTPUT_FILTER[*]}" ] || OUTPUT_FILTER=( cat )

  local SED_HRMNZ_JSON='
    s~(":\s*)undefined$~\1{}~
    1!{
      s~^"~\f\f\n\n\n\r&~
      #s~\f~//…\f…\n~g
      # ^-- problem: patch chunk length changes if we lose a line
      s~\f~\n~g
    }
    s~\}$~&,~
    s~(\{)(\},)$~\1\n\2~
    s~(^|\n)( *\S)~\1  \2~g
    '

  local P_OFFSET="$(grep -nPe '^\s*\x22\w+endencies\x22:' -m 1 \
    -- "$MANI_BFN" | grep -oPe '^\d+')"
  [ -n "$P_OFFSET" ] && P_OFFSET='/^@@ /s~(\s[+-])[0-9]+~\1'"$P_OFFSET~g"
  # P_OFFSET=

  diff -sU 2 --label known.deps --label found.deps <(
    scan_manifest_deps $(printf '%s\n' "${KNOWN_DEP_TYPES[@]}" | csort
      ) | sed -re "$SED_HRMNZ_JSON"
    ) <(
      dump_deps_as_json | sed -re "$SED_HRMNZ_JSON"
    ) | sed -re '
    /^\-{3}\s/d
    /^\+{3}\s/d
    /^\s*$/d
    '"$P_OFFSET" | "${OUTPUT_FILTER[*]}"
  return $(math_sum "${PIPESTATUS[@]}")
}


function update_manifest () {
  local P_DIFF="$(compare_deps_as_json | sed -re "$P_OFFSET"; echo :)"
  P_DIFF="${P_DIFF%:}"
  P_DIFF="${P_DIFF%$'\n'}"
  "${COLORIZE_DIFF:-cat}" <<<"$P_DIFF"
  case "$P_DIFF" in
    '@@'* ) ;;
    *' identical'* ) return 0;;
    * ) fail 'failed to parse diff report.'; return 4;;
  esac

  local P_OPTS=(
    --batch
    --forward
    --backup-if-mismatch
    --fuzz=0
    --reject-file=-   # discard
    --suffix=.bak-$$
    --unified
    --verbose
    # --dry-run
    )

  local P_HEAD=$'--- old/%\n+++ new/%\n'
  P_HEAD="${P_HEAD//%/$MANI_BFN}"
  patch "${P_OPTS[@]}" "$MANI_BFN" <(echo "$P_HEAD$P_DIFF") 2>&1 | sed -re '
    1{
      : buffer
        /\n[Pp]atching /{s~^.*\n~~;b copy}
      N;b buffer
      : copy
    }
    /\.{3}\s*$/{N;s~\.{3,}~…~g;s~\s*\n~ ~}
    /^[Dd]one\.?$/d
    '
  return $?
}


function csort () {
  LANG=C sort "$@"; return $?
}


function guess_cwd_pkg_name () {
  local PKGN="$(read_json_subtree '' .name | sed -nre 's~^"(\S+)"$~\1~p')"
  if [ -n "$PKGN" ]; then
    safe_pkg_names "$PKGN" && return 0
    echo "W: module name from manifest looks too scary: $PKGN" >&2
  fi
  PKGN="$(basename "$PWD")"
  echo "W: unable to detect module name from manifest," \
    "will use current directory's name instead: $PKGN" >&2
  echo "$PKGN"
}


function scan_manifest_deps () {
  local DEP_TYPE=
  for DEP_TYPE in "$@"; do
    printf '"%sendencies": ' "$DEP_TYPE"
    read_json_subtree '' ."$DEP_TYPE"endencies || return $?
  done
  [ -n "$DEP_TYPE" ] && return 0  # Feature: '' as last arg = add all known
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    [ -n "$DEP_TYPE" ] || continue
    "$FUNCNAME" "$DEP_TYPE" || return "$DEP_TYPE"
  done
  return 0
}


function tabulate_manifest_deps () {
  progress 'I: Reading known deps: '
  local DEP_TYPE=
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    scan_manifest_deps "$DEP_TYPE" | sed -re '
      /":\s+(\{|undefined)$/d
      /^\s*\},?/d
      s~^\s*"([^"]+)":\s*"([^"]+)",?\s*$~'"$DEP_TYPE"'\t\1\t\2~
      '
  done
}


function progress () {
  [ "$DBGLV" -lt 1 ] && return 0
  local MSG="$*"
  echo -n "$MSG"
  case "$MSG" in
    *' ' ) ;;
    * ) echo;;
  esac
}


function read_json_subtree () {
  local SRC_FN="$1"; shift
  [ -n "$SRC_FN" ] || SRC_FN="$MANI_BFN"
  [ -s "$SRC_FN" ] || return 4$(fail "file not found: $SRC_FN")
  local SUBDOT="$1"; shift
  [ "${SRC_FN:0:1}" == / ] || SRC_FN="./$SRC_FN"
  SRCFN="$SRC_FN" nodejs -p '
    JSON.stringify(require(process.env.SRCFN)'"$SUBDOT, null, 2)"
}


function fail () {
  echo "E: $*" >&2
  return 2
}


function lncnt () {
  [ -n "$1" ] && wc -l <<<"$1"
}


function fastfind () {
  local PRUNES=( '(' -false
    -o -name .git
    -o -name .svn
    -o -name node_modules
    -o -name bower_components
    ')' -prune ',' )
  find -xdev "${PRUNES[@]}" "$@"
  return $?
}


function find_imports_in_files () {
  if [ "$1" == --guess-types ]; then
    shift
    "$FUNCNAME" "$@" | csort -u | with_stdin_args guess_dep_types | csort -u
    return $(math_sum "${PIPESTATUS[@]}")
  fi
  [ "$#" == 0 ] && return 0
  grep -HoPe '^\s*(import|\W*from)\s.*$|require\([^()]+\)' -- "$@" \
    | tr "'" '"' | sed -nre '
    s~\s+~ ~g
    s~^(\./|)([^: ]+):~\2\t~
    s~^(\S+)\trequire\("([^"]+)"\)$~\2\t\1~p
    /^\S+\s+import/{
      /"/!{$!N
        s~^.*\n(\./|)([^: ]+):~\2 ~
      }
      s~\s+~ ~g
      s~^(\S+ )import "~\1 from "~
      s~^(\S+) (.* |)from "([^"]+)"[; ]*~\3\t\1~p
    }
    ' | sed -re '
    # remove paths from module IDs (mymodule/path/to/file.js)
    s~^([a-z0-9_-]+)/\S+\t~\1\t~
    '
}


function math_sum () {
  local SUM="$*"
  let SUM="${SUM// /+}"
  echo "$SUM"
}


function with_stdin_args () {
  local CMD=( "$@" )
  [ -n "$1" ] || CMD=( printf 'D: arg: "%s"\n' )
  local ARGS=()
  tty --silent && progress "H: Enter arguments for ${CMD[*]}," \
    "one per line, Ctrl-D to process:"
  readarray -t ARGS
  "${CMD[@]}" "${ARGS[@]}"
  return $?
}


function safe_pkg_names () {
  local RGX='(@<id>/|)<id>'
  RGX="${RGX//<id>/[a-z][a-z0-9_-]*}"
  local FLT=( grep -xPe "$RGX" )
  if [ "$#" == 0 ]; then
    "${FLT[@]}"
    return $?
  fi
  printf '%s\n' "$@" | "${FLT[@]}"
  return $?
}


function guess_one_dep_type () {
  local REQ_MOD="$1"; shift
  local REQ_FILE="$1"; shift
  local DEP_TYPE=dep
  local RESOLVED=
  local DEP_VER=

  case "$REQ_MOD" in
    "$CWD_PKG_NAME" ) DEP_TYPE=self-ref; DEP_VER='*';;
    . | ./* | .. | ../* ) DEP_TYPE=relPath; DEP_VER='*';;
    * )
      [ -n "$(safe_pkg_names "$REQ_MOD")" ] || continue$(
        echo "W: skip dep: scary module name: $REQ_MOD" >&2)
      ;;
  esac


  [ "$DEP_TYPE" == dep ] && RESOLVED="$(nodejs -p '
    require.resolve(process.argv[1])' "$REQ_MOD")"
  if [ "$RESOLVED" == "$REQ_MOD" ]; then
    DEP_TYPE=built-in
    RESOLVED=''
    DEP_VER='*'
  fi

  [ -n "$DEP_VER" ] || DEP_VER="$(nodejs -p '
    require(require.resolve(process.argv[1])).version
    ' "$REQ_MOD/$MANI_BFN")"

  local SUBDIR=
  if [ "$DEP_TYPE" == dep ]; then
    SUBDIR="${REQ_FILE%%/*}"
    case "${SUBDIR%s}" in
      doc | demo | test ) DEP_TYPE=devDep;;
    esac
    case "$REQ_FILE" in
      */* ) ;;    # files in subdirs are handled above
      # below: top-level files
      test.* ) DEP_TYPE=devDep;;
    esac
  fi

  echo -n "$DEP_TYPE"
  echo -n $'\t'"$REQ_MOD"
  echo -n $'\t'"$DEP_VER"
  # echo -n $'\t'"$RESOLVED"
  echo
}

function guess_dep_types () {
  for REQ_MOD in "$@"; do
    REQ_FILE="${REQ_MOD##*$'\t'}"
    REQ_MOD="${REQ_MOD%$'\t'*}"
    guess_one_dep_type "$REQ_MOD" "$REQ_FILE" || return $?
  done
  return 0
}


















[ "$1" == --lib ] && return 0; guess_js_deps "$@"; exit $?
