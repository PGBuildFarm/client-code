#!/bin/sh

for f in `make -s show`
do
	grep -q Copyright $f || sed -i '3r copyright.template' $f
done

DT=`date +%Y`

for f in `make -s show`
do
	sed -i "s/2003-20.., Andrew Dunstan/2003-$DT, Andrew Dunstan/" $f
done
