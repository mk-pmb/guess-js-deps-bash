#!/bin/sed -urf
# -*- coding: UTF-8, tab-width: 2 -*-

s~^\s+~~
s~\s+$~~
/^$/d

/^eslint:/d
s~^([a-z]+:|)(\@[^/]+/|)~\a<user>\2 \a<mode>\1 \a<esl>~
s~\a<mode>(plugin): (\a<esl>)(eslint-plugin-|)~\2eslint-\1-~
s~\a<mode> ~~

s~\a<esl>(eslint-)~\a<pkg>\1~
s~\a<esl>~\a<pkg>eslint-config-~
s~(\a<pkg>[^/]+)/\S+~\1~
s~\a<user>(\S*) \a<pkg>~\1~
