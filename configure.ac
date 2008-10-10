#                                               -*- Autoconf -*-
# Process this file with autoconf to produce a configure script.
AC_PREREQ(2.59)
AC_INIT(flare, 1.0.0)
AC_CONFIG_SRCDIR(src/flared/flared.cc)
AM_INIT_AUTOMAKE
AM_CONFIG_HEADER(src/config.h)
AC_CANONICAL_HOST

# Checks for programs.
AC_PROG_CXX
AC_PROG_CC
AC_PROG_RANLIB

# Checks for libraries.
AC_ARG_WITH(boost,
	[  --with-boost            boost libraries],
	[CXXFLAGS="${CXXFLAGS} -I${withval}/include" LDFLAGS="${LDFLAGS} -L${withval}/lib"])
AC_CHECK_LIB(boost_program_options, main, [], [echo "libboost_program_options not found"; exit 1])
AC_CHECK_LIB(boost_regex, main, [], [echo "libboost_regex not found"; exit 1])

AC_CHECK_LIB(pthread, pthread_create, [], [echo "libpthread not found"; exit 1])

AC_ARG_WITH(tokyocabinet,
	[  --with-tokyocabinet     tokyocabinet libraries],
	[CXXFLAGS="${CXXFLAGS} -I${withval}/include -I${withval}/include/tc" LDFLAGS="${LDFLAGS} -L${withval}/lib"])
AC_CHECK_LIB(tokyocabinet, main, [], [echo "libtokyocabinet not found"; exit 1])

# Checks for header files.
AC_STDC_HEADERS
AC_CHECK_HEADER(pthread.h, [], [echo "pthread.h not found"; exit1])

# Checks for typedefs, structures, and compiler characteristics.

# Checks for library functions.

# And others

#   debug options
AC_ARG_ENABLE(debug, [AC_HELP_STRING([--enable-debug], [enable debug compile [default=no]])], [], [enable_debug="no"])
if test "x$enable_debug" = "xno"
then
	DEBUG_DEFS=""
else
	DEBUG_DEFS="-DDEBUG"
fi

AC_ARG_ENABLE(memory-allocation-check, [AC_HELP_STRING([--enable-memory-allocation-check], [enable memory allocation check procs [default=no]])], [], [enable_memory_allocation_check="no"])
if test "x$enable_memory_allocation_check" = "xno"
then
	DEBUG_DEFS="${DEBUG_DEFS}"
else
	DEBUG_DEFS="${DEBUG_DEFS} -DMM_ALLOCATION_CHECK"
fi

#   pthread options
case $host_os in
	linux-gnu)
		echo "setting thread flags...-pthread"
		PTHREAD_DEFS="-pthread -D_REENTRANT -D_THREAD_SAFE"
		;;
	*)
		echo "host_os [$host_os] is not yet supported"
		exit 1;
		;;
esac

FLARE_CXXFLAGS="$DEBUG_DEFS $PTHREAD_DEFS"
FLARE_LDFLAGS=""

AC_SUBST(FLARE_CXXFLAGS)
AC_SUBST(FLARE_LDFLAGS)

# Outputs
AC_CONFIG_FILES([Makefile \
    src/Makefile \
	src/lib/Makefile \
	src/flared/Makefile \
	src/flarem/Makefile])
AC_OUTPUT
