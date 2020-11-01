#!/bin/sed -urf
# -*- coding: UTF-8, tab-width: 2 -*-

s~^(demo-util-160404)-test-demos(\t)~lib-\1\2~
s~^(uglify)(js\t)~\1-\2~
s~^(yaml)(lint\t)~\1-\2~
