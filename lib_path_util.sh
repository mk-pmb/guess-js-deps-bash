#!/bin/bash
# -*- coding: utf-8, tab-width: 2 -*-


function path_util__common_prefix  () {
  local A="$1"; shift
  local B="$1"; shift
  while [[ "$B" == */ ]]; do B="${B%/}"; done
  while [ -n "$A" ]; do
    case "$B" in
      "$A" | "$A"/* ) break;;
    esac
    A="${A%/*}"
  done
  [ -n "$A" ] || return 3
  echo "$A"
  return 0
}


function path_util__relativize_sanely () {
  local DEST="$1"; shift
  local BASE="$1"; shift
  local ABS_LCPP="$(path_util__common_prefix "$BASE" "$DEST")"
  # echo "D: ABS_LCPP='$ABS_LCPP'" >&2
  case "$ABS_LCPP" in
    /home | \
    /media | \
    /mnt | \
    '' ) return 3;;
  esac
  BASE="${BASE#$ABS_LCPP/}"
  DEST="${DEST#$ABS_LCPP/}"
  local UP="${BASE//[^\/]/}/"
  UP="${UP//\//..\/}"
  # echo "D: base='$BASE' up='$UP' sub='$DEST'" >&2
  echo "$UP$DEST"
}






[ "$1" == --lib ] && return 0; path_util__"$@"; exit $?
