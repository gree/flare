if WITH_CUTTER
noinst_LTLIBRARIES =	\
	test-storage-tc.la \
	test-key-resolver-modular.la
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

test_storage_tc_la_SOURCES	= test-storage-tc.cc
test_key_resolver_modular_la_SOURCES	= test-key-resolver-modular.cc
