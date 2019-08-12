#!/bin/bash
# -*- coding: utf-8, tab-width: 2 -*-


function guess_js_deps () {
  export LANG{,UAGE}=en_US.UTF-8  # make error messages search engine-friendly

  local SELFPATH="$(readlink -m "$BASH_SOURCE"/..)"
  #cd "$SELFPATH" || return $?
  source "$SELFPATH"/lib_dict_util.sh --lib || exit $?
  source "$SELFPATH"/lib_path_util.sh --lib || exit $?

  # import AUTOGUESS_SHEBANG_CMDS and AUTOGUESS_BUILD_UTIL_CMDS:
  source "$SELFPATH"/autoguess_config.txt --lib || exit $?

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
    sym )     OUTPUT_MODE=( symlink_nonlocal_node_modules );;
    manif )   read_json_subtree "$@"; return $?;;
    scan-imports )    find_imports_in_files "$@"; return $?;;
    scan-known )      scan_manifest_deps; return $?;;
    scan-manif )      find_manif_script_deps "$@"; return $?;;
    scan-eslint-cfg ) find_manif_eslint_deps "$@"; return $?;;
    tabulate-found )  OUTPUT_MODE=( 'fmt://tsv' );;
    tabulate-known )  tabulate_manifest_deps; return $?;;
    --func ) "$@"; return $?;;
    * ) fail "unsupported runmode: $RUNMODE"; return 2;;
  esac

  find_imports_in_project "${OUTPUT_MODE[@]}"
}


function init_resolve_cache () {
  # echo "D: ${FUNCNAME[*]}: <${!RESOLVE_CACHE[*]}>" >&2
  [ -n "${!RESOLVE_CACHE[*]}" ] && return 0
  echo "local -A RESOLVE_CACHE=( ['?canhaz?']=+ )"
}


function find_imports_in_project () {
  local THEN=( "$@" )
  local CWD_PKG_NAME="$(guess_cwd_pkg_name)"
  progress 'I: Searching for JavaScript files: '
  local -A DEPS_BY_TYPE=()
  eval "$(init_resolve_cache)"
  local IMPORTS=()
  IMPORTS=(
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

  progress 'I: Searching for require()s/imports: '
  readarray -t IMPORTS < <( (
    find_imports_in_files "${IMPORTS[@]}"
    find_manif_script_deps
    find_manif_eslint_deps
    ) | guess_unique_stdin_dep_types)
  progress 'done.'

  if [ "${OUTPUT_MODE[0]}" == 'fmt://tsv' ]; then
    printf '%s\n' "${IMPORTS[@]}"
    return 0
  fi
  dict_split_tsv_by_1st_column DEPS_BY_TYPE "${IMPORTS[@]}"
  merge_redundant_devdeps
  progress "found $(<<<"${DEPS_BY_TYPE[dep]}" grep . | wc -l) deps" \
    "and $(<<<"${DEPS_BY_TYPE[devDep]}" grep . | wc -l) devDeps."
  [ "$DBGLV" -ge 2 ] && dump_dict DEPS_BY_TYPE | sed -re '
    s~^\S+~Found: &~;s~^~D: ~'

  "${THEN[@]}"; return $?
}


function find_manif_script_deps () {
  local SCRIPTS=()
  readarray -t SCRIPTS < <(fastfind -name '*.sh')
  ( </dev/null grep -HvPe '^\s*(#[^!]|$)' -- "${SCRIPTS[@]}"
    read_json_subtree '' .scripts | sed -nre '
      s~^\s*"([^"]+)": "~\v<manif>scripts/\1 ~p'
  ) | sed -nre '
    s~^\./~~
    s![\a\t\r]+! !g
    s~\b($bogus^'"$(printf '|%s' "${AUTOGUESS_BUILD_UTIL_CMDS[@]}"
      )"')([$ &|()<>]|$|\x22|\x27)~\a\1 ~gp
    /\a/{
      /^\v/!s~:~\r~
      s~^\v<(manif)>(\S+) ~\1://\2\r ~
      s~^~\n~
      : add_filename
        s~(\n(\S+)\r)[^\a]*\a(\S+) ~\n\3\t\2\1 ~
      t add_filename
      s~\n[^\n\t]+$~~
      p
    }
    ' | grep -Pe '\t'
}


function find_manif_eslint_deps () {
  local GUESS_LONG_PKGNAMES='
    /\S/!d
    /^eslint:/d
    s~^([a-z]+:|)(\@[^/]+/|)~\a<user>\2 \a<mode>\1 \a<esl>~
    s~\a<mode>(plugin): (\a<esl>)(eslint-plugin-|)~\2eslint-\1-~
    s~\a<mode> ~~

    s~\a<esl>(eslint-)~\a<pkg>\1~
    s~\a<esl>~\a<pkg>eslint-config-~
    s~(\a<pkg>[^/]+)/\S+~\1~
    s~\a<user>(\S*) \a<pkg>~\1~

    s~$~\tmanif://lint~
    '
  read_json_subtree '' .eslintConfig.extends 2>/dev/null \
    | tr '",[]' '\n' | sed -rf <(echo "$GUESS_LONG_PKGNAMES")
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


function find_dep_keys_line_numbers () {
  nl -ba -nln -w1 -s: -- "${1:-$MANI_BFN}" | sed -nre '
    s~^([0-9]+):\s*\x22([a-z]*dep)endencies\x22:.*$~[\2]=\1~ip'
}


function dump_deps_as_json () {
  local NUMBER_VERSION_PREFIX='^'
  local DEP_TYPE=
  for DEP_TYPE in "$@"; do
    printf '"%sendencies": ' "$DEP_TYPE"
    <<<"${DEPS_BY_TYPE[$DEP_TYPE]}" sed -re '
      1{${s~^$~{},~}}
      /\t/{
        s~^~  "~
        s~(\t)([0-9])~\1'"$NUMBER_VERSION_PREFIX"'\2~
        s~\t~": "~
        s~$~",~
        1s~^~{\n~
        $s~,$~\n},~
      }
      '
  done
  [ -n "$DEP_TYPE" ] && return 0  # Feature: '' as last arg = add all known
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    [ -n "$DEP_TYPE" ] || continue
    "$FUNCNAME" "$DEP_TYPE" || return $?
  done
}


function compare_deps_as_json () {
  if [ -n "$*" ]; then
    # output filter
    "$FUNCNAME" | "$@"
    return $?
  fi

  local DEP_TYPE=
  local SED_HRMNZ_JSON='
    1s~(\{)\s*(\},?)$~\1\n\2~
    $s~\}$~&,~
    s~^|\n~&  ~g
    '

  eval local -A DEP_OFFSETS="( $(find_dep_keys_line_numbers) )"
  local OFFS=
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    OFFS="${DEP_OFFSETS[$DEP_TYPE]}"
    [ -n "$OFFS" ] && OFFS="$(head --bytes="$OFFS" /dev/zero | tr -c : :)"
    OFFS="${OFFS%:}"
    OFFS="${OFFS//:/$'\n'}"
    diff -sU 1 --label known_"$DEP_TYPE"s <(
      echo -n "$OFFS"
      scan_manifest_deps "$DEP_TYPE" | sed -re "$SED_HRMNZ_JSON"
      ) --label found_"$DEP_TYPE"s <(
      echo -n "$OFFS"
      dump_deps_as_json  "$DEP_TYPE" | sed -re "$SED_HRMNZ_JSON"
      ) | sed -re '
      1{/^\-{3} /d}
      2{/^\+{3} /d}
      /^@@ /s~$~ '"$DEP_TYPE"'s~'
  done
}


function update_manifest () {
  local P_DIFF="$(compare_deps_as_json; echo :)"
  # The colon is to protect a trailing whitespace, which should be
  # redundant in bash but it's too subtle a bug to risk it.
  P_DIFF="${P_DIFF%:}"
  P_DIFF="${P_DIFF%$'\n'}"
  "${COLORIZE_DIFF:-cat}" <<<"$P_DIFF"

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
  patch "${P_OPTS[@]}" "$MANI_BFN" <(<<<"$P_HEAD$P_DIFF" sed -re '
    /^Files .* are identical\.?$/d
    ') 2>&1 | sed -re '
    1{
      : buffer
        /\n[Pp]atching /{s~^.*\n~~;b copy}
        N
      b buffer
      : copy
    }
    /\.{3}\s*$/{N;s~\.{3,}~…~g;s~\s*\n~ ~}
    /^[Dd]one\.?$/d
    '
  return $?
}


function csort () { LANG=C sort "$@"; }


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
    read_json_subtree '' ."$DEP_TYPE"'endencies || {}' || return $?
  done
  [ -n "$DEP_TYPE" ] && return 0  # Feature: '' as last arg = add all known
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    [ -n "$DEP_TYPE" ] || continue
    "$FUNCNAME" "$DEP_TYPE" || return $?
  done
}


function tabulate_manifest_deps () {
  progress 'I: Reading known deps: '
  local DEP_TYPE=
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    scan_manifest_deps "$DEP_TYPE" | sed -re '
      /^"[A-Za-z]+":\s*\{\}?$/d
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


function fail () { echo "E: $*" >&2; return 2; }
function lncnt () { [ -n "$1" ] && wc -l <<<"$1"; }


function node_resolve () {
  MOD_NAME="$1" nodejs -p 'require.resolve(process.env.MOD_NAME)'
}


function node_detect_manif_version () {
  # We can't easily cache the results here from the inside,
  # because this function is meant to run in a subshell.
  MANIF="$1/$MANI_BFN" nodejs -p '
    var m = require(process.env.MANIF), iu = (m.npmInstallUrl || false);
    (iu.default
      || m.version)'
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
  [ "$#" == 0 ] && return 0
  eval "$(init_resolve_cache)"
  LANG=C grep -PHone '#!.*$|^(\xEF\xBB\xBF|)\s*'$(
    )'(import|\W*from)\s.*$|require\([^()]+\)' -- "$@" \
    | tr "'" '"' | LANG=C sed -re '
    s~\s+~ ~g
    s~^(\./|)([^: ]+):~\2\t~
    s~^(\S+\t)\xEF\xBB\xBF~\1~
    ' | LANG=C sed -nre '
    /\t1:#!/{
      s~^(\S+)\t#! *(/\S*\s*|)\b($bogus^'"$(
        printf '|%s' "${AUTOGUESS_SHEBANG_CMDS[@]}"
        )"')\b(\s.*|)$~\3\t\1~p
    }
    s~\t[0-9]:~\t~  # other match types work w/o line numbers.
    s~^(\S+)\trequire\("([^"]+)"\)$~\2\t\1~p
    /^\S+\s+import/{
      /"/!{$!N
        s~^.*\n(\./|)([^: ]+):~\2 ~
      }
      s~\s+~ ~g
      s~^(\S+ )import "~\1 from "~
      s~^(\S+) (.* |)from "([^"]+)";?\s*(/[/*].*|)$~\3\t\1~p
    }
    ' | sed -re '
    # remove paths from module IDs (mymodule/path/to/file.js)
    s~^((@[a-z0-9_-]+/|)([a-z0-9_-]+))/\S+\t~\1\t~
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
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" | "$FUNCNAME"
    return $?
  fi
  local LN= PKG= ORG=
  local ID_RGX='^[a-z][a-z0-9_.-]*$'
  local RV=3
  while read -r LN; do
    PKG="$LN"
    ORG=
    case "$PKG" in
      '' ) continue;;
      @*/* )
        ORG="${PKG%%/*}"
        PKG="${PKG#*/}"
        ORG="${ORG#\@}"
        ;;
    esac
    [[ "$PKG" =~ $ID_RGX ]] || continue
    [ -z "$ORG" ] || [[ "$ORG" =~ $ID_RGX ]] || continue
    echo "$LN"
    RV=0
  done
  return "$RV"
}


function guess_one_dep_type () {
  local REQ_MOD="$1"; shift
  local REQ_FILE="$1"; shift
  local DEP_TYPE=dep
  local RESOLVED=
  local DEP_VER=

  case "$REQ_MOD" in
    "$CWD_PKG_NAME" ) DEP_TYPE='self-ref'; DEP_VER='*';;
    . | ./* | .. | ../* ) DEP_TYPE='relPath'; DEP_VER='*';;
    * )
      [ -n "$(safe_pkg_names "$REQ_MOD")" ] || continue$(
        echo "W: skip dep: scary module name: $REQ_MOD" >&2)
      ;;
  esac

  if [ "$DEP_TYPE" == dep ]; then
    RESOLVED="${RESOLVE_CACHE[$REQ_MOD?file]}"
    if [ -z "$RESOLVED" ]; then
      RESOLVED="$(node_resolve "$REQ_MOD" 2>/dev/null)"
      RESOLVE_CACHE["$REQ_MOD?file"]="$RESOLVED"
    fi
  fi
  if [ "$RESOLVED" == "$REQ_MOD" ]; then
    DEP_TYPE=built-in
    RESOLVED=''
    DEP_VER='*'
  fi

  if [ -z "$DEP_VER" ]; then
    DEP_VER="${RESOLVE_CACHE[$REQ_MOD?ver]}"
    if [ -z "$DEP_VER" ]; then
      DEP_VER="$(node_detect_manif_version "$REQ_MOD" 2>/dev/null)"
      if [ -z "$DEP_VER" ]; then
        DEP_VER='?unknown?'
        RESOLVE_CACHE['?unknown?']+=" $REQ_MOD"
      fi
      RESOLVE_CACHE["$REQ_MOD?ver"]="$DEP_VER"
    fi
  fi

  local SUBDIR=
  if [ "$DEP_TYPE" == dep ]; then
    SUBDIR="${REQ_FILE%%/*}"
    case "${SUBDIR%s}" in
      build | \
      demo | \
      doc | \
      test ) DEP_TYPE=devDep;;
    esac
    case "$REQ_FILE" in
      manif://scripts/*lint* | \
      manif://scripts/*test* | \
      manif://lint ) DEP_TYPE=devDep;;
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


function guess_unique_stdin_dep_types () {
  with_stdin_args guess_dep_types | csort -u
}


function guess_dep_types () {
  eval "$(init_resolve_cache)"
  local REQ_MOD=
  local REQ_FILE=
  for REQ_MOD in "$@"; do
    REQ_FILE="${REQ_MOD##*$'\t'}"
    REQ_MOD="${REQ_MOD%$'\t'*}"
    guess_one_dep_type "$REQ_MOD" "$REQ_FILE" || return $?
  done

  local UNKN="${RESOLVE_CACHE['?unknown?']}"
  [ -z "$UNKN" ] || echo "W: modules with unknown versions:$UNKN" >&2
}


function merge_redundant_devdeps () {
  # Assumption: If dupes exist, they will be exact (esp. same version)
  # because we guessed those version anyway. (The source files didn't
  # care about versions.)
  # Thus we can just eliminate devDeps that are also deps:
  DEPS_BY_TYPE[devDep]="$(
    <<<"${DEPS_BY_TYPE[devDep]}" grep -vxFe "${DEPS_BY_TYPE[dep]}")"
  return 0
}


function symlink_nonlocal_node_modules () {
  local DEP_TYPE=
  local DEP_LIST=()
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    DEP_LIST[0]+="${DEPS_BY_TYPE[$DEP_TYPE]}"$'\n'
  done
  readarray -t DEP_LIST < <( <<<"${DEP_LIST[0]}" cut -sf 1 | csort -u )
  [ -n "${DEP_LIST[*]}" ] || return 0

  local DEP_NAME= M_RESO=
  local ABSPWD="$(readlink -m .)"
  local MOD_DIR='node_modules/'
  local MOD_SEARCH_DIRS=(
    "$HOME/.$MOD_DIR"
    "$HOME/lib/$MOD_DIR"
    "$HOME"
    )
  local DEST= LINK= LDIR_ABS=
  local DEP_MISS=()
  for DEP_NAME in "${DEP_LIST[@]}"; do
    [ -f "$MOD_DIR$DEP_NAME/$MANI_BFN" ] && continue
    # if not in local node_modules, ascend:
    M_RESO="$(node_resolve "$DEP_NAME/$MANI_BFN" 2>/dev/null)"
    if [ ! -f "$M_RESO" ]; then
      echo "W: failed to resolve $DEP_NAME/$MANI_BFN" >&2
      DEP_MISS+=( "$DEP_NAME" )
      continue
    fi
    M_RESO="${M_RESO%/$MANI_BFN}"

    LINK="$MOD_DIR$DEP_NAME"
    LDIR_ABS="$ABSPWD/$(dirname "$LINK")"
    [ "$(readlink -m -- "$LDIR_ABS")" == "$LDIR_ABS" ] || return 4$(
      echo "E: flinching from stramhe path effects in $LDIR_ABS" >&2)
    [ "$LDIR_ABS" == "$M_RESO" ] && return 3$(
      echo "E: flinching from linking $M_RESO into itself" >&2)
    mkdir --parents --verbose -- "$LDIR_ABS"
    DEST="$(path_util__relativize_sanely "$M_RESO" "$LDIR_ABS")"
    if [ -z "$DEST" ]; then
      for DEST in "${MOD_SEARCH_DIRS[@]}"; do
        DEST="${DEST%/}/$DEP_NAME"
        [ "$(readlink -m -- "$DEST")" == "$M_RESO" ] && break
        DEST=
      done
    fi
    [ -n "$DEST" ] || DEST="$M_RESO"
    # printf "D: %s='%s'\n" link "$LINK" dest "$DEST" reso "$M_RESO" >&2
    # echo >&2 D:
    ln --verbose --symbolic --no-target-directory \
      -- "$DEST" "$LINK" || return $?
  done

  if [ -n "${DEP_MISS[*]}" ]; then
    echo "E: unresolved deps (n=${#DEP_MISS[@]}): ${DEP_MISS[*]}" >&2
    return 4
  fi
}





















[ "$1" == --lib ] && return 0; guess_js_deps "$@"; exit $?
