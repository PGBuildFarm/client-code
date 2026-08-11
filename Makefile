
# Copyright (c) 2003-2010, Andrew Dunstan

# See accompanying License file for license details

# Our perl lives in exactly two places: scripts at the top level, and the
# PGBuild hierarchy. Name those rather than walking the whole tree and
# pruning what turns up, which meant every new directory -- buildroots,
# sandbox, results/ -- had to be excluded by hand as it appeared. That
# matters most for tidy, which would otherwise rewrite files in results/,
# where review artifacts and plans live.
ALLPERLFILES = $(shell find . -maxdepth 1 \( -name '*.pl' -o -name '*.pm' \) -print | sed 's!\./!!'; find PGBuild \( -name '*.pl' -o -name '*.pm' \) -print) build-farm.conf.sample

# these are the explicitly selected perl files that will go in a 
# release tarball
PERLFILES = run_build.pl run_web_txn.pl run_branches.pl \
	update_personality.pl setnotes.pl manage_alerts.pl \
	build-farm.conf.sample  \
	PGBuild/SCM.pm PGBuild/Options.pm PGBuild/WebTxn.pm PGBuild/Utils.pm \
	PGBuild/Log.pm PGBuild/VSenv.pm \
	PGBuild/Modules/Skeleton.pm \
	PGBuild/Modules/TestUpgrade.pm \
	PGBuild/Modules/FileTextArrayFDW.pm PGBuild/Modules/BlackholeFDW.pm \
	PGBuild/Modules/PGXSExtension.pm \
	PGBuild/Modules/TestCollateLinuxUTF8.pm \
	PGBuild/Modules/TestSepgsql.pm \
	PGBuild/Modules/TestUpgradeXversion.pm \
	PGBuild/Modules/TestICU.pm \
	PGBuild/Modules/CheckHeaders.pm \
	PGBuild/Modules/CheckPerl.pm \
	PGBuild/Modules/CheckIndent.pm \
	PGBuild/Modules/ABICompCheck.pm \
	PGBuild/Modules/Dist.pm \
	PGBuild/Modules/PatchStack.pm \
	PGBuild/Modules/RedisFDW.pm \
	PGBuild/Modules/TestMyTap.pm

OTHERFILES = License README

RELEASE_FILES = $(PERLFILES) $(OTHERFILES)

ALLFILES = $(ALLPERLFILES) $(OTHERFILES)

CREL := $(if $(REL),$(strip $(subst .,_, $(REL))),YOU_NEED_A_RELEASE)

.PHONY: tag release copyright syncheck tidy critic clean show perlcheck

tag:
	@test -n "$(REL)" || (echo Missing REL && exit 1)
	sed -i -e "s/VERSION = '[^']*';/VERSION = 'REL_$(CREL)';/" $(ALLFILES)
	git commit -a -m 'Mark Release '$(REL)
	git tag -m 'Release $(REL)' REL_$(CREL)
	@echo Now do: git push --tags origin main

release:
	@test -n "$(REL)" || (echo Missing REL && exit 1)
	@echo REL = $(CREL)
	tar -z --xform="s,^,build-farm-$(REL)/,S" $(RELEASE_FILES) -cf releases/build-farm-$(CREL).tgz


copyright:
	./make_copyright.sh

tidy:
	perltidy $(ALLPERLFILES)

syncheck:
	for f in $(ALLPERLFILES) ; do perl -I. -cw $${f}; done;

critic:
	perlcritic -3 --theme core $(ALLPERLFILES)

perlcheck: syncheck critic

clean:
	find . "(" -name '*.bak' -o -name '*.orig' -o -name '*~' ")" -type f -exec rm -f {} \;

show:
	@echo $(ALLPERLFILES)
