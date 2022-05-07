#!/bin/bash
# -*- coding: utf-8, tab-width: 2 -*-


function guess_js_deps () {
  export LANG{,UAGE}=en_US.UTF-8  # make error messages search engine-friendly

  local SELFPATH="$(readlink -m "$BASH_SOURCE"/..)"
  #cd -- "$SELFPATH" || return $?
  source "$SELFPATH"/lib_dict_util.sh --lib || exit $?
  source "$SELFPATH"/lib_path_util.sh --lib || exit $?

  # import AUTOGUESS_SHEBANG_CMDS and AUTOGUESS_BUILD_UTIL_CMDS:
  source "$SELFPATH"/autoguess_config.txt --lib || exit $?

  local DBGLV="${DEBUGLEVEL:-0}"
  local COLORIZE_DIFF="$(can_haz_cmd colordiff)"
  local MANI_BFN='package.json'
  local KNOWN_DEP_TYPES=(
    dep
    devDep
    peerDep
    )

  local RUNMODE="$1"; shift
  case "$RUNMODE" in
    '..' | '../'* )
      cd -- "$RUNMODE" # probably to where your package.json is.
      RUNMODE="$1"
      shift;;
  esac
  local OUTPUT_MODE=( fail 'Unsupported output mode. This is a bug.' )
  case "$RUNMODE" in
    as-json ) OUTPUT_MODE=( dump_deps_as_json );;
    '' | \
    cmp )     OUTPUT_MODE=( maybe_colorize_diff compare_deps_as_json );;
    upd )     OUTPUT_MODE=( update_manifest );;
    sym )     OUTPUT_MODE=( symlink_nonlocal_node_modules );;

    usy )
      OUTPUT_MODE=( output_multi
        update_manifest
        symlink_nonlocal_node_modules
      );;

    why )
      scan_all_scannable_files_in_project \
        | guess_unique_stdin_dep_types
      return $?;;

    manif )   read_json_subtree "$@"; return $?;;
    list-files )      find_scannable_files_in_project; return $?;;
    scan-all )        scan_all_scannable_files_in_project; return $?;;
    scan-imports )    warn_no_args find_imports_in_files "$@"; return $?;;
    scan-known )      scan_manifest_deps; return $?;;
    scan-manif )      find_manif_script_deps "$@"; return $?;;
    scan-eslint-cfg ) find_manif_eslint_deps "$@"; return $?;;
    guess-types )     guess_unique_stdin_dep_types; return $?;;
    tabulate-found )  OUTPUT_MODE=( 'fmt://tsv' );;
    tabulate-known )  tabulate_manifest_deps; return $?;;
    --func ) "$@"; return $?;;
    * ) fail "unsupported runmode: $RUNMODE"; return 2;;
  esac

  find_imports_in_project "${OUTPUT_MODE[@]}"
}


function warn_no_args () {
  [ "$#" -ge 2 ] || echo "W: Calling $1 with no arguments!" >&2
  "$@"; return $?
}


function maybe_colorize_diff () {
  [ -z "$*" ] || exec < <("$@")
  "${COLORIZE_DIFF:-cat}"
}


function init_resolve_cache () {
  # echo "D: ${FUNCNAME[*]}: <${!RESOLVE_CACHE[*]}>" >&2
  [ -n "${!RESOLVE_CACHE[*]}" ] && return 0
  echo "local -A RESOLVE_CACHE=( ['?canhaz?']=+ )"
  echo "${FUNCNAME}__prep || return $?"
}


function init_resolve_cache__prep () {
  init_resolve_cache__webpack_cfg || return $?
  init_resolve_cache__forced_custom || return $?
}


function init_resolve_cache__webpack_cfg () {
  local WPCFG='./webpack.config.js'
  [ -f "$WPCFG" ] || return 0
  local VAL="$(nodejs -p "Object.keys(require('./webpack.config.js'
    ).resolve.alias).join('\n')" 2>/dev/null)"
  [ -z "$VAL" ] || RESOLVE_CACHE['?packer/alias_pkgnames']+="$VAL"$'\n'
}


function init_resolve_cache__forced_custom () {
  local LIST=()
  readarray -t LIST < <(
    nodejs -p 'var manif = require("./package.json"); JSON.stringify([
      manif.dependencies,
      manif.devDependencies,
    ], null, 2)' | sed -nrf <(echo '
      s~^\s+"~~
      s~",?$~~
      s~": "([a-z]\S+/\S+#\S)~\t\1~p
    '))
  local KEY= VAL=
  for VAL in "${LIST[@]}"; do
    KEY="${VAL%%$'\t'*}"
    VAL="${VAL#*$'\t'}"
    RESOLVE_CACHE["$KEY?ver"]="$VAL"
  done
}


function find_scannable_files_in_project () {
  local FF=(
    -type f
    '(' -name '*.js'
        -o -name '*.mjs'
        -o -name '*.jsm'
        -o -name '*.html'
        ')'
    )
  fastfind "${FF[@]}" || return $?
}


function scan_all_scannable_files_in_project () {
  if [ "$1" == --reuse-imports-array ]; then
    shift
  else
    local IMPORTS=()
  fi

  progress 'I: Searching for JavaScript files: '
  readarray -t IMPORTS < <(find_scannable_files_in_project)
  progress "found ${#IMPORTS[@]}"

  progress 'I: Searching for require()s/imports: '
  find_imports_in_files "${IMPORTS[@]}"
  find_manif_script_deps
  find_manif_eslint_deps
  find_simple_html_script_deps
}


function find_imports_in_project () {
  local THEN=( "$@" )
  local CWD_PKG_NAME="$(guess_cwd_pkg_name)"
  local -A DEPS_BY_TYPE=()
  eval "$(init_resolve_cache)"

  local IMPORTS=()
  readarray -t IMPORTS < <(
    scan_all_scannable_files_in_project \
      | guess_unique_stdin_dep_types 1-3)
  progress 'done.'

  [ -n "${IMPORTS[0]}" ] || return 3$(
    fail "Unable to find any import()s/imports in package: $CWD_PKG_NAME")

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
  ) | sed -nrf <(echo '
    s~^\./~~
    s![\a\t\r]+! !g
    s~\b($bogus^'"$(printf '|%s' "${AUTOGUESS_BUILD_UTIL_CMDS[@]}"
      )"')([$ &|()<>]|$|\x22|\x27)~\a\1 ~g
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
    ') | grep -Pe '\t' | "$SELFPATH"/manif_script_cmd2pkg.sed
}


function find_manif_eslint_deps () {
  local DEPS="$(find_manif_eslint_deps__scan)"
  [ -n "$DEPS" ] || return 0
  local SCRIPTS="$(read_json_subtree '' .scripts values)"

  local BUF="$DEPS"
  BUF="¶ ${BUF//$'\n'/ ¶ } ¶"
  BUF="${BUF//$'\t'/ » }"

  local ECNP='eslint-config-nodejs-pmb'
  case "$BUF" in
    *"¶ $ECNP "* )
      local PEER_DEPS="$ECNP/test/expectedPeerDependencies.js"
      PEER_DEPS="require('$PEER_DEPS').join('\n')"
      PEER_DEPS="$(nodejs -p "$PEER_DEPS")"
      [ -n "$PEER_DEPS" ] || return 4$(
        echo "E: Failed to detect peer dependencies of $ECNP" >&2)
      DEPS+=$'\n'"$PEER_DEPS"
      <<<"$SCRIPTS" grep -qoPe '^\s*"elp[ \&"]' && DEPS+=$'\neslint-pretty-pmb'
      ;;
  esac

  <<<"$DEPS" sed -re 's~\S$~&\tmanif://lint~'
}


function find_manif_eslint_deps__scan () {
  local ESLC="$SELFPATH"/eslint_cfg_
  ( read_json_subtree '' .eslintConfig.extends
    "$ESLC"scan_deps.sed .eslintrc.yaml
  ) 2>/dev/null | tr '",[]' '\n' \
    | sed -rf "$ESLC"guess_long_pkgnames.sed
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
  LANG=C sed -nrf <(echo '
    s~^\s*"([a-z]*dep)endencies"(\s*:)~\1\n\2~i
    /\n/{
      s~^(\S+)\n([:{}, \t\r]*).*$~[\1:empty]="\2"\n[\1]=\a~
      p
      =
    }') -- "${1:-$MANI_BFN}" | LANG=C sed -rf <(echo '
      /:empty]="/{
        /\]=""$/d
        /\}/!d
      }
      /=\a$/{N;s~\a\n~~}
    ')
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


function output_multi () {
  local FUNC= RV= MAX_ERR=0
  for FUNC in "$@"; do
    "$FUNC"; RV=$?
    [ "$RV" -gt "$MAX_ERR" ] && MAX_ERR="$RV"
  done
  return "$MAX_ERR"
}


function sed_hrmnz_json () {
  LANG=C sed -re '
    1s~(\{)\s*(\},?)$~\1\n\2~
    $s~\}$~&,~
    s~^|\n~&  ~g
    '
}


function compare_deps_as_json () {
  local VERBATIM_EMPTY_ORIG=
  case "$1" in
    '' ) ;;
    --empty-orig=verbatim ) VERBATIM_EMPTY_ORIG=+;;
    * ) echo "E: $FUNCNAME: invalid option: '$1'" >&2; return 8;;
  esac

  eval local -A DEP_OFFSETS="( $(find_dep_keys_line_numbers) )"

  local DEP_TYPE=
  for DEP_TYPE in "${KNOWN_DEP_TYPES[@]}"; do
    compare_deps_as_json__one_dep_type || return $?
  done
}


function compare_deps_as_json__one_dep_type () {
  local OFFS="${DEP_OFFSETS[$DEP_TYPE]}"
  local OLD_JSON="$(scan_manifest_deps "$DEP_TYPE" | sed_hrmnz_json)"
  local UPD_JSON="$(dump_deps_as_json  "$DEP_TYPE" | sed_hrmnz_json)"
  if [ "$OLD_JSON" == "$UPD_JSON" ]; then
    echo "D: no changes in ${DEP_TYPE}s"
    return 0
  fi

  local EMPTY="${DEP_OFFSETS[$DEP_TYPE:empty]}"
  if [ -n "$VERBATIM_EMPTY_ORIG" -a -n "$EMPTY" ]; then
    local UPD_LNCNT="${UPD_JSON//[!$'\n']/}"
    UPD_LNCNT="${UPD_LNCNT//$'\n'/:}:"
    UPD_LNCNT="${#UPD_LNCNT}"
    echo "@@ -$OFFS,1 +$OFFS,$UPD_LNCNT @@"
    echo '-  "'"$DEP_TYPE"'endencies"'"$EMPTY"
    echo "+${UPD_JSON//$'\n'/$'\n'+}"
    return 0
  fi

  [ -z "$OFFS" ] || printf -v OFFS '%*s' "$OFFS" ''
  OFFS="${OFFS% }"
  OFFS="${OFFS// /$'\n'}"
  diff -sU 1 --label known_"$DEP_TYPE"s <(
    echo "$OFFS$OLD_JSON"
    ) --label found_"$DEP_TYPE"s <(
    echo "$OFFS$UPD_JSON"
    ) | sed -re '
    1{/^\-{3} /d}
    2{/^\+{3} /d}
    /^@@ /s~$~ '"$DEP_TYPE"'s~'
}


function update_manifest () {
  local P_DIFF="$(compare_deps_as_json --empty-orig=verbatim; echo :)"
  # The colon is to protect potential trailing whitespace, which should be
  # redundant in bash but it's too subtle a bug to risk it.
  P_DIFF="${P_DIFF%:}"
  P_DIFF="${P_DIFF%$'\n'}"
  maybe_colorize_diff <<<"$P_DIFF"

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
  PKGN="$(basename -- "$PWD")"
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
  local SUBDOT="$1"; shift
  local FX="$1"; shift
  [ -n "$SRC_FN" ] || SRC_FN="$MANI_BFN"
  [ -s "$SRC_FN" ] || return 4$(fail "file not found: $SRC_FN")
  [ "${SRC_FN:0:1}" == / ] || SRC_FN="./$SRC_FN"
  local CODE="require(process.env.SRCFN)$SUBDOT"
  case "$FX" in
    keys | values ) CODE="Object.$FX($CODE || false)";;
  esac
  CODE="JSON.stringify($CODE, null, 2)"
  SRCFN="$SRC_FN" nodejs -p "$CODE"
}


function fail () { echo "E: $*" >&2; return 2; }
function lncnt () { [ -n "$1" ] && wc -l <<<"$1"; }


function node_resolve () {
  local ID="$1"
  local BUF="$(nodejs -p 'require.resolve(process.argv[1])' \
    -- "$ID" 2>&1 | sed -re 's~^\s+~ ~')"
  case "$BUF" in
    /* ) # resolved to a file's absolute path
      echo "$BUF"; return 0;;
    *[^a-z0-9_]* ) # probably not a built-in module
      ;;
    "$ID" ) # built-in module
      echo "$BUF"; return 0;;
  esac
  node_resolve__manif && return 0
  echo "E: $FUNCNAME($ID): unsupported output from node.js: $BUF" >&2
  return 3
}


function node_resolve__manif () {
  case "$ID" in
    */"$MANI_BFN" ) ;;
    * ) return 2;;
  esac
  local NDEF=$'^\n\nError [ERR_PACKAGE_PATH_NOT_EXPORTED]: Package subpath '$(
    )"'./package.json'"' is not defined by "exports" in '
  local FOUND=
  case "$BUF" in
    *"$NDEF"*$'\n at '* )
      FOUND="${BUF#*"$NDEF"}"
      FOUND="${FOUND%%$'\n at '*}"
      if [ -f "$FOUND" ]; then
        echo "$FOUND"
        return 0
      fi
      ;;
  esac
  return 2
}


function node_detect_manif_version () {
  # We can't easily cache the results here from the inside,
  # because this function is meant to run in a subshell.
  local MANI="$1/$MANI_BFN"
  local RESO="$(node_resolve "$MANI")"
  [ -f "$RESO" ] || return 4$(echo "E: $FUNCNAME: Cannot find $MANI" >&2)
  RESO="$RESO" nodejs <<<'
    var m = require(process.env.RESO), iu = (m.npmInstallUrl || false);
    console.log(iu.default
      || m.version);'
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
  local SBC_RGX='($bogus^'"$(printf '|%s' "${AUTOGUESS_SHEBANG_CMDS[@]}"))"

  LANG=C grep -PHone '#!.*$|^(\xEF\xBB\xBF|)\s*'$(
    )'(import|\W*from)\s.*$|require\([^()]+\)' -- "$@" \
    | tr "'" '"' | LANG=C sed -rf <(echo '
    s~\s+~ ~g
    s~^(\./|)([^: ]+):~\2\t~
    s~^(\S+\t[0-9]+:)\xEF\xBB\xBF~\1~
    ') | LANG=C sed -nrf <(echo '
    /\t1:#!/{
      s~^(\S+)\t1:#! *(/\S*\s*|)\b'"$SBC_RGX"'\b(\s.*|)$~\3\t\1~p
    }
    s~\t[0-9]+:~\t~  # other match types work w/o line numbers.
    s~^(\S+)\trequire\("([^"]+)"\)$~\2\t\1~p
    /^\S+\s+import/{
      /"/!{$!N
        s~^.*\n(\./|)([^: ]+):~\2 ~
      }
      s~\s+~ ~g
      s~^(\S+ )import "~\1 from "~
      s~^(\S+) (.* |)from "([^"]+)";?\s*(/[/*].*|)$~\3\t\1~p
    }
    ') | remove_paths_from_module_ids
}


function remove_paths_from_module_ids () {
  # remove paths from module IDs (mymodule/path/to/file.js)

  local SUBPATH_RGX='/\S*'
  # Actual subpath is optional: Trailing slash notation is used in
  # ubborg-planner-pmb's slashableImport.

  sed -rf <(echo '
    s~^((@[a-z0-9_-]+/|)([a-z0-9_-]+))'"$SUBPATH_RGX"'(\t|$)~\1\4~
    ') -- "$@" || return $?
}


function find_simple_html_script_deps () {
  progress 'I: Searching for HTML files: ' >&2
  local LIST=(
    -type f
    '(' -name '*.html'
        ')'
    )
  readarray -t LIST < <(fastfind "${LIST[@]}")
  progress "found ${#LIST[@]}" >&2
  [ "${#LIST[@]}" == 0 ] && return 0
  local SRC_FN= TAGS= DEP=
  local Q='"'
  local MODBASE_RGX='(\.*/)*node_modules/'
  local SRC_ATTR_RX=' src="'"$MODBASE_RGX"'[^"]+"'
  for SRC_FN in "${LIST[@]}"; do
    SRC_FN="${SRC_FN#\./}"
    readarray -t LIST < <(<"$SRC_FN" tr -s '\r\n\t ' ' ' \
      | grep -oPe '<script\b[^<>]+>' | grep -oPe "$SRC_ATTR_RX" \
      | cut -d "$Q" -sf 2 | sed -re "s~^$MODBASE_RGX~~
      " | remove_paths_from_module_ids)
    for DEP in "${LIST[@]}"; do
      echo "$DEP"$'\t'"$SRC_FN"
    done
  done
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
  esac

  if [ -z "$DEP_VER" ]; then
    case $'\n'"${RESOLVE_CACHE['?packer/alias_pkgnames']}"$'\n' in
      *$'\n'"${REQ_MOD%%/*}"$'\n'* )
        DEP_TYPE='packer-alias'
        DEP_VER='*';;
    esac
  fi

  [ -n "$DEP_VER" ] || [ -n "$(safe_pkg_names "$REQ_MOD")" ] || return 0$(
    echo "W: skip dep: scary module name: $REQ_MOD" >&2)

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
  local REQ_NORM_FEXT="$REQ_FILE"
  REQ_NORM_FEXT="${REQ_NORM_FEXT/%.js/.%JS}"
  REQ_NORM_FEXT="${REQ_NORM_FEXT/%.mjs/.%JS}"
  if [ "$DEP_TYPE" == dep ]; then
    SUBDIR="${REQ_FILE%%/*}"
    case "${SUBDIR%s}" in
      build | \
      debug | \
      demo | \
      doc | \
      test ) DEP_TYPE=devDep;;
    esac
    case "$REQ_NORM_FEXT" in
      */webpack.config.js | \
      manif://scripts/*lint* | \
      manif://scripts/*test* | \
      manif://lint ) DEP_TYPE=devDep;;
      */* ) ;;    # files in subdirs are handled above
      # below: top-level files
      *[.-]test.%JS | \
      test.* ) DEP_TYPE=devDep;;
    esac
  fi
  case "$DEP_TYPE:$REQ_MOD" in
    dep:eslin't' )
      # :TODO: Better way to opt-out from eslint guessing
      DEP_TYPE='peerDep';;
  esac

  echo -n "$DEP_TYPE"
  echo -n $'\t'"$REQ_MOD"
  echo -n $'\t'"$DEP_VER"
  echo -n $'\t'"$REQ_FILE"
  # echo -n $'\t'"$RESOLVED"
  echo
}


function guess_unique_stdin_dep_types () {
  local FIELDS="${1:-1-}"; shift
  csort --unique | with_stdin_args guess_dep_types | cut -sf "$FIELDS" \
    | csort --unique # <-- not --version-sort: would group "@" after "z"
}


function guess_dep_types () {
  eval "$(init_resolve_cache)"
  local SPURIOUS=$'\n'"$(read_json_subtree '' .spuriousDependencies \
    | sed -nre 's~^ *"(\S+)",?$~\1~p')"$'\n'
  local REQ_MOD=
  local REQ_FILE=
  for REQ_MOD in "$@"; do
    REQ_FILE="${REQ_MOD##*$'\t'}"
    REQ_MOD="${REQ_MOD%$'\t'*}"
    [[ "$SPURIOUS" == *$'\n'"$REQ_MOD"$'\n'* ]] && continue
    guess_one_dep_type "$REQ_MOD" "$REQ_FILE" || return $?
  done

  local UNKN="${RESOLVE_CACHE['?unknown?']}"
  [ -z "$UNKN" ] || echo "W: modules with unknown versions:$UNKN" >&2
}


function merge_redundant_devdeps () {
  # Assumption: If dupes exist, they will be exact (esp. same version)
  # because we guessed those version anyway. (The source files didn't
  # care about versions.)
  # Thus we can just eliminate devDeps that are also deps or peerDeps:
  local EXCLUDE="${DEPS_BY_TYPE[dep]}"
  EXCLUDE+=$'\n'"${DEPS_BY_TYPE[peerDep]}"
  DEPS_BY_TYPE[devDep]="$(<<<"${DEPS_BY_TYPE[devDep]}" grep -vxFe "$EXCLUDE")"
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
