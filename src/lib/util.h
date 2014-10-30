/**
 *	util.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef UTIL_H
#define UTIL_H

#include <vector>
#include <sstream>

#include <boost/detail/endian.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/regex.hpp>
#include <boost/shared_array.hpp>
#include <boost/tokenizer.hpp>

#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "config.h"
#include "logger.h"

#ifdef HAVE_LIBBOOST_ATOMIC
#include <boost/atomic.hpp>
#endif

using namespace std;

namespace gree {
namespace flare {

#ifndef BUFSIZ
#define	BUFSIZ	4096
#endif	// BUFSIZ

#define ATOMIC_ADD_X86_32(p,i,r) __asm__ __volatile__ ("lock; xaddl %0,%1" : "=r"(r), "=m"(*p) : "0"(i), "m" (*p))
#define ATOMIC_ADD_X86_64(p,i,r) __asm__ __volatile__ ("lock; xaddq %0,%1" : "=r"(r), "=m"(*p) : "0"(i), "m" (*p))
#define ATOMIC_ADD_PPC_32(p,i,r) __asm__ __volatile__ ("\n1:\n\tlwarx %0, 0, %1\n\tadd %0, %0, %2\n\tstwcx. %0, 0, %1\n\tbne- 1b\n\tsub %0, %0, %2" : "=&r" (r) : "r" (p), "r" (i) : "cc", "memory")


class AtomicCounter{
#if defined(HAVE_LIBBOOST_ATOMIC)
	boost::atomic<uint64_t> val;
#elif defined(HAVE_SYNC_FETCH_AND_ADD)
	uint64_t val;
#elif defined(__GNUC__) && defined (__x86_64__)
	uint64_t val;
#elif defined(__GNUC__)
	uint32_t val;
#else
#error "Can not find atomic-instruction."
#endif
public:
	inline AtomicCounter(uint64_t init_val):val(init_val){}

	inline uint64_t fetch(){
#if defined(HAVE_LIBBOOST_ATOMIC)
		return val;
#elif defined(HAVE_SYNC_FETCH_AND_ADD)
		return __sync_fetch_and_add(&val,0);
#else
		return val;
#endif
	}

	inline uint64_t add(uint64_t n){
#if defined(HAVE_LIBBOOST_ATOMIC)
		return val.fetch_add(n,boost::memory_order_relaxed);
#elif defined(HAVE_SYNC_FETCH_AND_ADD)
		return __sync_fetch_and_add(&val,n);
#elif defined(__GNUC__) && defined (__x86_64__)
		uint64_t r;
		ATOMIC_ADD_X86_64(&val,n,r);
		return r;
#elif defined(__GNUC__) && defined (__i386__)
		uint32_t r;
		ATOMIC_ADD_X86_32(&val,n,r);
		return r;
#elif defined(__GNUC__) && ( defined (__ppc__) || defined (__PPC__) )
		uint32_t r;
		ATOMIC_ADD_PPC_32(&val,n,r);
		return r;
#else
#error "Can not find atomic-instruction."
#endif
	}

	inline uint64_t incr(){
		return this->add(1);
	}

};


#ifdef HAVE_STDINT_H
# include <stdint.h>
#else
typedef unsigned char uint8_t;
#endif // HAVE_STDINT_H

extern const char* const line_delimiter;
typedef boost::shared_array<uint8_t> shared_byte;

/**
 *	utility class (misc methods)
 */
class util {
public:
	static const int max_realtime_delta = 60*60*24*30;		// from memcached.c

	static const char* strerror(int e);
	static const char* hstrerror(int e);
	static int gethostbyname(const std::string& host, int port, sa_family_t, sockaddr_in&, int& gai_errno, std::string* canonname = 0);
	static int inet_ntoa(struct in_addr in, char* dst);
	static in_addr_t inet_addr(const char *cp, const uint32_t netmask = 0xffffffff);
	static int get_fqdn(string& fqdn);
	static inline unsigned int next_word(const char* src, char* dst, unsigned int dst_len);
	static inline unsigned int next_digit(const char* src, char* dst, unsigned int dst_len);
	static time_t realtime(time_t t);
	static string base64_encode(const char* src, size_t src_size);
	static char* base64_decode(string src, size_t& dst_size);
	static inline bool is_unsigned_integer_string(const string s);

	template<class T> static string vector_join(vector<T> list, string glue);
	template<class T> static vector<T> vector_split(string s, string sep);
};

unsigned int util::next_word(const char* src, char* dst, unsigned int dst_len) {
	const char *p = src;
	char *q = dst;

	// sync w/ memcached behavior (cannot use isspace() here because memcached does not recognize '\t' and other space chars as ws)
	while (*p == ' ') {
		p++;
	}
	while (*p && *p != ' ' && *p != '\n' && static_cast<unsigned int>(q-dst)+1 < dst_len) {
		*q++ = *p++;
	}
	*q = '\0';

	return p-src;
}

unsigned int util::next_digit(const char* src, char* dst, unsigned int dst_len) {
	const char *p = src;
	char *q = dst;

	// sync w/ memcached behavior (cannot use isspace() here because memcached does not recognize '\t' and other space chars as ws)
	while (*p == ' ') {
		p++;
	}
	while (*p && (isdigit(*p) || *p == '-') && *p != '\n' && static_cast<unsigned int>(p-src) < dst_len) {
		*q++ = *p++;
	}
	*q = '\0';

	return p-src;
}

bool util::is_unsigned_integer_string(const string s) {
	const char *pattern = "\\A[0-9]+\\z";
	const boost::regex e(pattern);

	return boost::regex_match(s, e);
}

template<class T> string util::vector_join(vector<T> list, string glue) {
	ostringstream sout;
	typename vector<T>::iterator it;
	for (it = list.begin(); it != list.end(); it++) {
		if (sout.tellp() > 0) {
			sout << glue;
		}
		sout << *it;
	}

	return sout.str();
}

template<class T> vector<T> util::vector_split(string s, string sep) {
	vector<T> r;

	typedef boost::tokenizer<boost::char_separator<char> > tokenizer;
	boost::char_separator<char> separator(sep.c_str());
	tokenizer token_list(s, separator);
	for (tokenizer::iterator it = token_list.begin(); it != token_list.end(); it++) {
		r.push_back(boost::lexical_cast<T>(*it));
	}

	return r;
}

}	// namespace flare
}	// namespace gree

#endif // UTIL_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
