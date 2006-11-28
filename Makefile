
FILES = run_build.pl run_web_txn.pl update_personality.pl build-farm.conf

CREL := $(if $(REL),$(strip $(subst .,_, $(REL))),YOU_NEED_A_RELEASE)

.PHONY: tag
tag:
	cvs tag REL_$(CREL) $(FILES)

.PHONY: release
release:
	@echo REL = $(CREL)
	mkdir build-farm-$(REL)
	cp $(FILES) build-farm-$(REL)
	tar -z -cf build-farm-$(CREL).tgz build-farm-$(REL)
	rm -rf build-farm-$(REL)
