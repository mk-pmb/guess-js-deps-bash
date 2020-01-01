#!/bin/sed -urf
# -*- coding: UTF-8, tab-width: 2 -*-

s~^(demo-util-160404)-test-demos(\tmanif:)~lib-\1\2~
s~^(yaml)(lint\tmanif:)~\1-\2~
