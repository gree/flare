SUBDIRS =	\
	lib

TESTS =
TESTS_ENVIRONMENT =

if WITH_CUTTER
TESTS += run-tests.sh
TESTS_ENVIRONMENT += NO_MAKE=yes CUTTER="$(CUTTER)"
endif

if WITH_VALGRIND
TESTS += run-memory-tests.sh
TESTS_ENVIRONMENT += VALGRIND="$(VALGRIND)"
endif

EXTRA_DIST =		\
	run-tests.sh	\
	run-memory-tests.sh

echo-cutter:
	@echo $(CUTTER)

echo-valgrind:
	@echo $(VALGRIND)
