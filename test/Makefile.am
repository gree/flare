SUBDIRS =	\
	lib

if WITH_CUTTER
TESTS = run-test.sh
TESTS_ENVIRONMENT = NO_MAKE=yes CUTTER="$(CUTTER)"
endif

EXTRA_DIST =					\
	run-test.sh

echo-cutter:
	@echo $(CUTTER)
