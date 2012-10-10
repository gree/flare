if WITH_CUTTER
noinst_LTLIBRARIES =	\
	test-storage.la \
	test-storage-tcb.la \
	test-storage-tch.la \
	test-key-resolver-modular.la \
	test-util.la
endif

INCLUDES =			\
	-I$(top_srcdir)		\
	-I$(top_srcdir)/src/lib

AM_CXXFLAGS =			\
	$(FLARE_CXXFLAGS)	\
	$(CPPCUTTER_CFLAGS)

AM_LDFLAGS =			\
	-module			\
	-rpath $(libdir)	\
	-avoid-version		\
	$(FLARE_LDFLAGS)

LIBS =						\
	$(top_builddir)/src/lib/libflare.la	\
	$(CPPCUTTER_LIBS)

test_storage_la_SOURCES	= test-storage.cc
test_storage_tcb_la_SOURCES	= test-storage-tcb.cc common-storage-tests.cc
test_storage_tch_la_SOURCES	= test-storage-tch.cc common-storage-tests.cc
test_key_resolver_modular_la_SOURCES	= test-key-resolver-modular.cc
test_util_la_SOURCES	= test-util.cc
