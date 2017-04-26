#!/bin/sh


find . -name '*.p[lm]' -print | while read f ; do
	grep -q Copyright $f || sed -i '3r copyright.template' $f
done

DT=`date +%Y`

find . -name '*.p[lm]' -print | while read f ; do
	sed -i "s/2003-20.., Andrew Dunstan/2003-$DT, Andrew Dunstan/" $f
done
