#!/bin/sed -nurf
# -*- coding: UTF-8, tab-width: 2 -*-

: skip
  /^extends:$/b extends
  /^plugins:$/b plugins
  n
b skip

: extends
  n
  /^\S/b skip
  s~^\s+\-?\s*~~
  /\S/p
b extends

: plugins
  n
  /^\S/b skip
  s~^\s+\-?\s*~~
  s~\S~plugin:~p
b plugins
