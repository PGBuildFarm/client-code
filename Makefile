
# Copyright (c) 2003-2010, Andrew Dunstan

# See accompanying License file for license details

FILES = run_build.pl run_web_txn.pl update_personality.pl \
	setnotes.pl build-farm.conf PGBuild/SCM.pm PGBuild/Options.pm

CREL := $(if $(REL),$(strip $(subst .,_, $(REL))),YOU_NEED_A_RELEASE)

.PHONY: tag
tag:
	sed -i -e "s/VERSION = '[^']*';/VERSION = 'REL_$(REL)';/" $(FILES)
	cvs ci -m "setting version for tag REL_$(CREL)" $(FILES)
	cvs tag REL_$(CREL) $(FILES)

.PHONY: release
release:
	@echo REL = $(CREL)
	mkdir build-farm-$(REL)
	tar -cf - $(FILES) | tar -C build-farm-$(REL) -xf -
	tar -z -cf build-farm-$(CREL).tgz build-farm-$(REL)
	rm -rf build-farm-$(REL)
