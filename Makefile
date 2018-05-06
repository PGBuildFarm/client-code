
# Copyright (c) 2003-2010, Andrew Dunstan

# See accompanying License file for license details

ALLPERLFILES = $(shell find . -path ./sandbox -prune -o \( -name '*.pl' -o -name '*.pm' \) -print | sed 's!\./!!') build-farm.conf.sample

# these are the explicitly selected perl files that will go in a 
# release tarball
PERLFILES = run_build.pl run_web_txn.pl run_branches.pl \
	update_personality.pl setnotes.pl \
	build-farm.conf.sample  \
	PGBuild/SCM.pm PGBuild/Options.pm PGBuild/WebTxn.pm PGBuild/Utils.pm \
	PGBuild/Modules/Skeleton.pm \
	PGBuild/Modules/TestUpgrade.pm \
	PGBuild/Modules/FileTextArrayFDW.pm PGBuild/Modules/BlackholeFDW.pm \
	PGBuild/Modules/TestDecoding.pm \
	PGBuild/Modules/TestCollateLinuxUTF8.pm \
	PGBuild/Modules/TestSepgsql.pm \
	PGBuild/Modules/TestUpgradeXversion.pm \
	PGBuild/Modules/TestICU.pm

OTHERFILES = License README

RELEASE_FILES = $(PERLFILES) $(OTHERFILES)

ALLFILES = $(ALLPERLFILES) $(OTHERFILES)

CREL := $(if $(REL),$(strip $(subst .,_, $(REL))),YOU_NEED_A_RELEASE)

.PHONY: tag
tag:
	@test -n "$(REL)" || (echo Missing REL && exit 1)
	sed -i -e "s/VERSION = '[^']*';/VERSION = 'REL_$(REL)';/" $(ALLFILES)
	git commit -a -m 'Mark Release '$(REL)
	git tag -m 'Release $(REL)' REL_$(CREL)
	@echo Now do: git push --tags origin master

.PHONY: release
release:
	@test -n "$(REL)" || (echo Missing REL && exit 1)
	@echo REL = $(CREL)
	tar -z --xform="s,^,build-farm-$(REL)/,S" $(RELEASE_FILES) -cf releases/build-farm-$(CREL).tgz

copyright:
	./make_copyright.sh

syncheck:
	for f in $(ALLPERLFILES) ; do perl -cw $${f}; done;

tidy:
	perltidy $(ALLPERLFILES)

critic:
	perlcritic -4 $(ALLPERLFILES)

clean:
	find . "(" -name '*.bak' -o -name '*.orig' -o -name '*~' ")" -type f -exec rm -f {} \;

show:
	@echo $(ALLPERLFILES)
