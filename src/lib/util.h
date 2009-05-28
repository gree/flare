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
#include <boost/shared_ptr.hpp>
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
typedef shared_ptr<uint8_t> shared_byte;

/**
 *	utility class (misc methods)
 */
class util {
public:
	static const int max_realtime_delta = 60*60*24*30;		// from memcached.c

	static const char* strerror(int e);
	static int gethostbyname(const char *name, struct hostent* he, int* he_errno);
	static int inet_ntoa(struct in_addr in, char* dst);
	static int get_fqdn(string& fqdn);
	static unsigned int next_word(const char* src, char* dst, unsigned int dst_len);
	static unsigned int next_digit(const char* src, char* dst, unsigned int dst_len);
	static time_t realtime(time_t t);
	static string base64_encode(const char* src, size_t src_size);
	static char* base64_decode(string src, size_t& dst_size);

	template<class T> static string vector_join(vector<T> list, string glue) {
		ostringstream sout;
		typename vector<T>::iterator it;
		for (it = list.begin(); it != list.end(); it++) {
			if (sout.tellp() > 0) {
				sout << glue;
			}
			sout << *it;
		}

		return sout.str();
	};

	template<class T> static vector<T> vector_split(string s, string sep) {
		vector<T> r;

		typedef boost::tokenizer<boost::char_separator<char> > tokenizer;
		boost::char_separator<char> separator(sep.c_str());
		tokenizer token_list(s, separator);
		for (tokenizer::iterator it = token_list.begin(); it != token_list.end(); it++) {
			r.push_back(lexical_cast<T>(*it));
		}

		return r;
	};
};

}	// namespace flare
}	// namespace gree

#endif // __UTIL_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
