#!/bin/bash
# -*- coding: utf-8, tab-width: 2 -*-
SELFPATH="$(readlink -m "$BASH_SOURCE"/..)"; INVOKED_AS="$(basename "$0" .sh)"

source "$SELFPATH"/lib_dict_util.sh --lib || exit $?


function guess_js_deps () {
  export LANG{,UAGE}=en_US.UTF-8  # make error messages search engine-friendly
  #cd "$SELFPATH" || return $?

  local DBGLV="${DEBUGLEVEL:-0}"
  local KNOWN_DEP_TYPES=( dep devDep )

  local RUNMODE="$1"; shift
  case "$RUNMODE" in
    '' ) RUNMODE='cmp';;
    as-json | cmp ) ;;
    scan-known ) scan_manifest_deps; return $?;;
    tabulate-known ) tabulate_manifest_deps; return $?;;
    scan-requires ) find_requires_in_files "$@"; return $?;;
    tabulate-found ) ;;
    --func ) "$@"; return $?;;
    * ) echo "E: $0: unsupported runmode: $RUNMODE" >&2; return 2;;
  esac

  local CWD_PKG_NAME="$(guess_cwd_pkg_name)"
  local REQUIRES=()
  progress 'I: Searching for *.js files: '
  readarray -t REQUIRES < <(fastfind -type f -name '*.js')
  progress "found ${#REQUIRES[@]}"
  [ -n "${REQUIRES[0]}" ] || return 3$(
    echo "E: Unable to find any require()s in package: $CWD_PKG_NAME" >&2)

  progress 'I: Searching for require()s in those files: '
  readarray -t REQUIRES < <(
    find_requires_in_files --guess-types "${REQUIRES[@]}")
  if [ "$RUNMODE" == tabulate-found ]; then
    printf '%s\n' "${REQUIRES[@]}"
    return 0
  fi
  local -A DEPS_BY_TYPE
  dict_split_tsv_by_1st_column DEPS_BY_TYPE "${REQUIRES[@]}"
  progress "found $(<<<"${DEPS_BY_TYPE[dep]}" grep . | wc -l) deps" \
    "and $(<<<"${DEPS_BY_TYPE[devDep]}" grep . | wc -l) devDeps."
  [ "$DBGLV" -ge 2 ] && dump_dict DEPS_BY_TYPE | sed -re '
    s~^\S+~Found: &~;s~^~D: ~'

  case "$RUNMODE" in
    as-json )
      dump_deps_as_json; return $?;;
    cmp )
      compare_deps_as_json; return $?;;
  esac

  echo 'E: unexpectedly unsupported runmode!' >&2
  return 5
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
  local SED_HRMNZ_JSON='
    s~(":\s*)undefined$~\1{}~
    s~\}$~&,~
    s~(\{)(\},)$~\1\n\2~
    '

  local COLORIZE=colordiff
  </dev/null "$COLORIZE" &>/dev/null || COLORIZE=

  diff -sU 2 --label known.deps --label found.deps <(scan_manifest_deps $(
    printf '%s\n' "${KNOWN_DEP_TYPES[@]}" | csort) | sed -re "$SED_HRMNZ_JSON"
    ) <(dump_deps_as_json | sed -re "$SED_HRMNZ_JSON") | sed -re '
    /^\-{3}\s/d
    /^\+{3}\s/d
    ' | "${COLORIZE:-cat}"
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
  [ -n "$SRC_FN" ] || SRC_FN='package.json'
  [ -s "$SRC_FN" ] || return 4$(echo "E: file not found: $SRC_FN" >&2)
  local SUBDOT="$1"; shift
  [ "${SRC_FN:0:1}" == / ] || SRC_FN="./$SRC_FN"
  SRCFN="$SRC_FN" nodejs -p '
    JSON.stringify(require(process.env.SRCFN)'"$SUBDOT, null, 2)"
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


function find_requires_in_files () {
  if [ "$1" == --guess-types ]; then
    shift
    "$FUNCNAME" "$@" | csort -u | with_stdin_args guess_dep_types | csort -u
    return $(math_sum "${PIPESTATUS[@]}")
  fi
  [ "$#" == 0 ] && return 0
  grep -HoPe 'require\([^()]+\)' -- "$@" | tr "'" '"' | sed -nre '
    s~^(\./|)(\S+):require\("([^"]+)"\)$~\3\t\2~p'
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
  local FLT=( grep -xPe '[a-z][a-z0-9_-]*' )
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
    ' "$REQ_MOD/package.json")"

  local SUBDIR=
  if [ "$DEP_TYPE" == dep ]; then
    SUBDIR="${REQ_FILE%%/*}"
    case "${SUBDIR%s}" in
      doc | demo | test ) DEP_TYPE=devDep;;
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
