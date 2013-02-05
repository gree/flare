/**
 *	htonll.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef __HTONLL_H__
#define __HTONLL_H__

#include <config.h>
#include <boost/detail/endian.hpp>
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

#if not defined HAVE_NTOHLL
#	if defined HAVE_BE64TOH
#		define ntohll(x) be64toh(x)
#		define htonll(x) htobe64(x)
# elif defined HAVE_BETOH64
#		define ntohll(x) betoh64(x)
#		define htonll(x) htobe64(x)
#	else
// Looks like we have to implement it ourselves...
#		if not HAVE_DECL_BSWAP64
#			if HAVE_DECL_BSWAP_64
#				define bswap64(x) bswap_64(x)
#			elif HAVE_DECL___BSWAP_64
#				define bswap64(x) __bswap_64(x)
#			else
#				define bswap64(x) \
					((((x) & 0xff00000000000000ull) >> 56)		\
					 | (((x) & 0x00ff000000000000ull) >> 40)	\
					 | (((x) & 0x0000ff0000000000ull) >> 24)	\
					 | (((x) & 0x000000ff00000000ull) >> 8)		\
					 | (((x) & 0x00000000ff000000ull) << 8)		\
					 | (((x) & 0x0000000000ff0000ull) << 24)	\
					 | (((x) & 0x000000000000ff00ull) << 40)	\
					 | (((x) & 0x00000000000000ffull) << 56))
#			endif
#		endif
#		if defined BOOST_LITTLE_ENDIAN
#			define ntohll(x) bswap64(x)
#			define htonll(x) bswap64(x)
#		else
#			define ntohll(x) (x)
#			define htonll(x) (x)
#		endif
#	endif
#endif

#endif // __HTONLL_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
