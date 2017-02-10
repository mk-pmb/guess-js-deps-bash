#!/bin/bash
# -*- coding: utf-8, tab-width: 2 -*-


function dict_split_tsv_by_1st_column () {
  local DICT_NAME="$1"; shift
  local ADD_CMD='[ -n "${§[$GRP]}" ] && §["$GRP"]+="$SEP"; §["$GRP"]+="$ITEM"'
  ADD_CMD="${ADD_CMD//§/$DICT_NAME}"
  local ITEM=
  local GRP=
  local SEP=$'\n'
  # echo "add: $ADD_CMD"
  for ITEM in "$@"; do
    GRP="${ITEM%%$'\t'*}"
    ITEM="${ITEM#*$'\t'}"
    [ -n "$GRP" ] || continue$(
      echo "W: $DICT_NAME: no group for item: $ITEM" >&2)
    eval "$ADD_CMD"
  done
}


function dump_dict () {
  local DICT_NAME="$1"; shift
  local DICT_KEYS=()
  eval 'DICT_KEYS=( "${!'"$DICT_NAME"'[@]}" )'
  local ITEM=
  for ITEM in "${DICT_KEYS[@]}"; do
    echo -n "$ITEM:"
    eval 'ITEM="${'"$DICT_NAME"'[$ITEM]}"'
    case "$ITEM" in
      *$'\n'* ) echo; nl -ba <<<"$ITEM";;
      * ) echo " [${#ITEM}] '$ITEM'";;
    esac
  done
}






[ "$1" == --lib ] && return 0; "$@"; exit $?
