/**
 *	util.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __UTIL_H__
#define __UTIL_H__

#include <vector>
#include <sstream>

#include <boost/lexical_cast.hpp>
#include <boost/tokenizer.hpp>

#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "config.h"
#include "mm.h"
#include "logger.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

#ifndef BUFSIZ
#define	BUFSIZ	4096
#endif	// BUFSIZ

// code from senna (http://qwik.jp/senna/)
#ifdef __GNUC__
#	if (defined(__i386__) || defined(__x86_64__))
#define ATOMIC_ADD(p,i,r) __asm__ __volatile__ ("lock; xaddl %0,%1" : "=r"(r), "=m"(*p) : "0"(i), "m" (*p))
#	elif (defined(__PPC__) || defined(__ppc__))
#define ATOMIC_ADD(p,i,r) __asm__ __volatile__ ("\n1:\n\tlwarx %0, 0, %1\n\tadd %0, %0, %2\n\tstwcx. %0, 0, %1\n\tbne- 1b\n\tsub %0, %0, %2" : "=&r" (r) : "r" (p), "r" (i) : "cc", "memory");
#	endif
#endif // __GNUC__

#ifdef HAVE_STDINT_H
# include <stdint.h>
#else
typedef unsigned char uint8_t;
#endif // HAVE_STDINT_H

extern const char* const line_delimiter;

/**
 *	utility class (misc methods)
 */
class util {
public:
	static const char* strerror(int e);
	static int gethostbyname(const char *name, struct hostent* he, int* he_errno);
	static int inet_ntoa(struct in_addr in, char* dst);
	static int get_fqdn(string& fqdn);
	static uint32_t next_word(const char* src, char* dst, uint32_t dst_len);
	static uint32_t next_digit(const char* src, char* dst, uint32_t dst_len);
	template<class T> static string vector_join(vector<T> list, string glue);
	template<class T> static vector<T> vector_split(string s, string sep);
};

}	// namespace flare
}	// namespace gree

#endif // __UTIL_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
