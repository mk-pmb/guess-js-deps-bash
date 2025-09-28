#!/bin/bash
# -*- coding: utf-8, tab-width: 2 -*-


function path_util__common_prefix  () {
  local A="$1"; shift
  local B="$(path_util__trim_trailing_slashes "$1")"; shift
  while [ -n "$A" ]; do
    case "$B" in
      "$A" | "$A"/* ) break;;
    esac
    case "$A" in
      */* ) A="${A%/*}";;
      * ) return 3;;
    esac
  done
  [ -n "$A" ] || return 3
  echo "$A"
  return 0
}


function path_util__trim_trailing_slashes () {
  while [ "$1" != / ] && [[ "$1" == */ ]]; do set -- "${1%/}"; done
  echo "$1"
}


function path_util__relativize_sanely () {
  local DEST="$(path_util__trim_trailing_slashes "$1")"; shift
  local BASE="$(path_util__trim_trailing_slashes "$1")"; shift
  local ABS_LCPP="$(path_util__common_prefix "$BASE" "$DEST")"
  # echo "D: ABS_LCPP='$ABS_LCPP'" >&2
  case "$ABS_LCPP" in
    /home | \
    /media | \
    /mnt | \
    '' ) return 3;;
  esac
  [ "$DEST" != "$ABS_LCPP" ] || DEST=
  DEST="${DEST#$ABS_LCPP/}"
  [ "$BASE" != "$ABS_LCPP" ] || BASE=
  BASE="${BASE#$ABS_LCPP/}"

  # For proper "up" counting by slashes, every path segment in BASE must
  # end with a slash. So if there are any, we need to add the trailing
  # slash for the last segment:
  [ -z "$BASE" ] || BASE+=/
  local UP="${BASE//[^\/]/}"
  UP="${UP//'/'/'../'}"
  # echo "D: base='$BASE' up='$UP' sub='$DEST'" >&2
  echo "$UP$DEST"
}






[ "$1" == --lib ] && return 0; path_util__"$@"; exit $?
