#                                               -*- Autoconf -*-
# Process this file with autoconf to produce a configure script.

AC_PREREQ(2.59)
AC_INIT(flare, 1.1.1)
AC_CONFIG_SRCDIR(src/flared/flared.cc)
AM_INIT_AUTOMAKE
AC_CONFIG_HEADERS(src/config.h)
AC_CANONICAL_HOST


# Checks for programs.

AC_PROG_CXX
AC_PROG_CC
AC_PROG_RANLIB
AC_PROG_LIBTOOL
AC_LANG(C++)

# Valgrind
AC_ARG_ENABLE(valgrind-checks,
	AS_HELP_STRING([--disable-valgrind-checks], [valgrind memory checks]))
AS_IF([test "x$enable_valgrind_checks" != "xno"],
	[AC_PATH_PROGS(VALGRIND, valgrind)])
AS_IF([test "x$ac_cv_path_VALGRIND" == "x" -a "x$enable_valgrind_checks" == "xyes"], [AC_MSG_ERROR(valgrind-checks requested but valgrind not found)])
AC_CHECK_HEADERS([valgrind.h valgrind/valgrind.h])


# Checks for libraries.

# Required libraries
AC_ARG_WITH(boost,
	AS_HELP_STRING([--with-boost], [boost libraries]),
	[CXXFLAGS="${CXXFLAGS} -I${withval}/include" LDFLAGS="${LDFLAGS} -L${withval}/lib"])
AC_CHECK_LIB(boost_program_options, main, [], [AC_CHECK_LIB(boost_program_options-mt, main, [], [AC_MSG_ERROR(boost_program_options not found)])])
AC_CHECK_LIB(boost_regex, main, [], [AC_CHECK_LIB(boost_regex-mt, main, [], [AC_MSG_ERROR(boost_regex not found)])])
AC_CHECK_LIB(boost_serialization, main, [], [AC_CHECK_LIB(boost_serialization-mt, main, [], [AC_MSG_ERROR(boost_serialization not found)])])
AC_CHECK_LIB(boost_thread, main, [], [AC_CHECK_LIB(boost_thread-mt, main, [], [AC_MSG_ERROR(boost_thread not found)])])
AC_CHECK_LIB(pthread, pthread_create, [], [AC_MSG_ERROR(libpthread not found)])
AC_CHECK_LIB(z, main, [], [AC_MSG_ERROR(zlib not found)])
AC_CHECK_LIB(hashkit, libhashkit_murmur, [], [AC_MSG_ERROR(libhashkit not found)])

# Tokyo Cabinet
AC_ARG_WITH(tokyocabinet,
	AS_HELP_STRING([--with-tokyocabinet], [tokyocabinet libraries]),
	[CXXFLAGS="${CXXFLAGS} -I${withval}/include -I${withval}/include/tc" LDFLAGS="${LDFLAGS} -L${withval}/lib"])
AC_CHECK_LIB(tokyocabinet, main, [], [AC_MSG_ERROR(tokyocabinet not found)])

# Kyoto Cabinet
AC_ARG_WITH(kyotocabinet,
	AS_HELP_STRING([--with-kyotocabinet], [kyotocabinet libraries]),
	AS_IF([test "$withval" != "no"], [CXXFLAGS="${CXXFLAGS} -I${withval}/include -I${withval}/include/kc" LDFLAGS="${LDFLAGS} -L${withval}/lib"], []))
AS_IF([test "x$with_kyotocabinet" != "xno"],
	[AC_CHECK_LIB(kyotocabinet, main, [], [])], [ac_cv_lib_kyotocabinet_main=no])
AS_IF([test "x$ac_cv_lib_kyotocabinet_main" = "xyes"],
	[],
	[AS_IF([test "x$with_kyotocabinet" != "x" -a "x$with_kyotocabinet" != "xno"],
		[AC_MSG_ERROR([kyotocabinet requested but not found])
		])
	])

# libuuid
AC_CHECK_LIB(uuid, main, [], [echo "libuuid not found"; exit 1])

# libzookeeper
AC_ARG_WITH(zookeeper,
	AS_HELP_STRING([--with-zookeeper], [zookeeper libraries]),
	AS_IF([test "$withval" != "no"], [CXXFLAGS="${CXXFLAGS} -I${withval}/include -I${withval}/include/zookeeper" LDFLAGS="${LDFLAGS} -L${withval}/lib"], []))
AS_IF([test "x$with_zookeeper" != "xno"],
	[AC_CHECK_LIB(zookeeper_mt, main, [], [])], [ac_cv_lib_zookeeper_mt_main=no])
AS_IF([test "x$ac_cv_lib_zookeeper_mt_main" = "xyes"],
	[AC_DEFINE([THREADED], [], [enable multi-threaded zookeeper library])],
	[AS_IF([test "x$with_zookeeper" != "x" -a "x$with_zookeeper" != "xno"],
		[AC_MSG_ERROR([zookeeper requested but not found])
		])
	])

# Checks for additional features

# Kyoto Cabinet
AM_CONDITIONAL(ENABLE_KYOTOCABINET, test "$ac_cv_lib_kyotocabinet_main" = "yes")

# libzookeeper
AM_CONDITIONAL(ENABLE_ZOOKEEPER, test "$ac_cv_lib_zookeeper_mt_main" = "yes")

# MySQL replication
AC_MSG_CHECKING(if mysql replication is enabled)
AC_ARG_ENABLE(mysql-replication, [AS_HELP_STRING([--enable-mysql-replication], [enable mysql replication feature (very experimental) [default=no]])], [enable_mysql_replication="yes"], [enable_mysql_replication="no"])
if test "x$enable_mysql_replication" = "xyes"
then
	AC_DEFINE([ENABLE_MYSQL_REPLICATION], 1, [enable mysql replication feature or not])
fi
AC_MSG_RESULT($enable_mysql_replication)

# FlareFS
AC_MSG_CHECKING(if flarefs is enabled)
AC_ARG_ENABLE(flarefs, [AS_HELP_STRING([--enable-flarefs], [enable flarefs feature (very experimental) [default=no]])], [enable_flarefs="yes"], [enable_flarefs="no"])
AC_MSG_RESULT($enable_flarefs)
AM_CONDITIONAL(ENABLE_FLAREFS, test "$enable_flarefs" = "yes")
if test "x$enable_flarefs" = "xyes"
then
	AC_ARG_WITH(fuse,
		[  --with-fuse             fuse libraries],
		[CXXFLAGS="${CXXFLAGS} -I${withval}/include" LDFLAGS="${LDFLAGS} -L${withval}/lib"])
	AC_CHECK_LIB(fuse, main, [], [AC_MSG_ERROR(libfuse not found)])
fi


# Checks for header files.

AC_STDC_HEADERS
AC_CHECK_HEADER(pthread.h, [], [AC_MSG_ERROR(pthread.h not found)])
AC_CHECK_HEADERS(arpa/inet.h endian.h sys/endian.h sys/types.h winsock2.h byteswap.h, [], [])
AC_CHECK_HEADER(boost/atomic.hpp,
[AC_DEFINE([HAVE_LIBBOOST_ATOMIC],[1],[have boost/atomic.hpp or not])],
[])

# Checks for typedefs, structures, and compiler characteristics.


# Checks for library functions.

AC_COMPILE_CHECK(
[whether we have __sync_fetch_and_add],
[#include <stdint.h>],
[uint64_t v;__sync_fetch_and_add(&v,1);],
[AC_DEFINE([HAVE_SYNC_FETCH_AND_ADD],[1],[have __sync_fetch_and_add])]
)

AC_CHECK_FUNC(epoll_create, [AC_DEFINE([HAVE_EPOLL], [], [have epoll functions or not])])
AC_CHECK_FUNC(kqueue, [AC_DEFINE([HAVE_KQUEUE], [], [have kqueue functions or not])])
AC_CHECK_DECLS([htonll, be64toh, betoh64, bswap64, bswap_64, __bswap_64], [], [], [
#ifdef HAVE_ARPA_INET_H
#	include <arpa/inet.h>
#endif
#ifdef HAVE_ENDIAN_H
#	include <endian.h>
#endif
#ifdef HAVE_SYS_ENDIAN_H
#	include <sys/endian.h>
#endif
#ifdef HAVE_SYS_TYPES_H
#	include <sys/types.h>
#endif
#ifdef HAVE_WINSOCK2_H
#	include <winsock2.h>
#endif
#ifdef HAVE_BYTESWAP_H
#	include <byteswap.h>
#endif
				])
AC_MSG_CHECKING(for gnu specific strerror_r)
AC_TRY_COMPILE([
#include <string.h>
#include <stdlib.h>
], [char* p = (char*)malloc(16); char* q = strerror_r(0, p, sizeof(16));], ac_strerror_r=yes, ac_strerror_r=no);
AC_MSG_RESULT($ac_strerror_r)
if test $ac_strerror_r = yes; then
	AC_DEFINE([HAVE_GNU_STRERROR_R], [], [have gnu specific strerror_r()])
fi


# And others...

# Debug options

AC_MSG_CHECKING(if debug is enabled)
AC_ARG_ENABLE(debug, [AS_HELP_STRING([--enable-debug], [enable debug compile [default=no]])], [enable_debug="yes"], [enable_debug="no"])
if test "x$enable_debug" = "xno"
then
	DEBUG_DEFS=""
else
	DEBUG_DEFS="-DDEBUG"
fi
AC_MSG_RESULT($enable_debug)

# Test

# Cutter
m4_ifdef([AC_CHECK_CPPCUTTER], [
AC_CHECK_CPPCUTTER
],
[ac_cv_use_cppcutter="no"])
AM_CONDITIONAL([WITH_CUTTER], [test "$ac_cv_use_cppcutter" != "no"])

# Valgrind
AM_CONDITIONAL([WITH_VALGRIND], [test "x$ac_cv_path_VALGRIND" != "x" -a "$ac_cv_use_cppcutter" != "no"])

# pthread options

PTHREAD_DEFS="-pthread -D_REENTRANT -D_THREAD_SAFE"


# Setup CXXFLAGS, LDFLAGS

FLARE_CXXFLAGS="$DEBUG_DEFS $PTHREAD_DEFS"
FLARE_LDFLAGS=""
AC_SUBST(FLARE_CXXFLAGS)
AC_SUBST(FLARE_LDFLAGS)


# Output

AC_CONFIG_FILES([Makefile \
	src/Makefile \
	src/lib/Makefile \
	src/flared/Makefile \
	src/flarei/Makefile \
	src/flarefs/Makefile \
	test/Makefile \
	test/lib/Makefile])
AC_OUTPUT
