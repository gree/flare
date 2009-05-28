/**
 *	util.cc
 *	
 *	implementation of gree::flare::util
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "app.h"
#include "util.h"

namespace gree {
namespace flare {

const char* const line_delimiter = "\r\n";

// {{{ ctor/dtor
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	strerror (thread safe)
 */
const char* util::strerror(int e) {
	static map<pthread_t, string> msg_map;
	char buf[BUFSIZ];

#ifdef HAVE_GNU_STRERROR_R
	char* p = strerror_r(e, buf, sizeof(buf));
	msg_map[pthread_self()] = p;
#else
	strerror_r(e, buf, sizeof(buf));
	msg_map[pthread_self()] = buf;
#endif // HAVE_GNU_STRERROR_R

	return msg_map[pthread_self()].c_str();
}

/**
 *	thread safe gethostbyname()
 */
int util::gethostbyname(const char *name, struct hostent* he, int* he_errno) {
#ifdef HAVE_GETHOSTBYNAME_R
	struct hostent* he_result;
	char he_buf[BUFSIZ];
	if (gethostbyname_r(name, he, he_buf, sizeof(he_buf), &he_result, he_errno) < 0) {
		log_err("gethostbyname_r() failed: %s (%d)", util::strerror(*he_errno), *he_errno);
		return -1;
	} 

	return 0;
#else
	static pthread_mutex_t m;
	static bool is_mutex_initialized = false;
	if (is_mutex_initialized == false) {
		pthread_mutex_init(&m, NULL);
		is_mutex_initialized = true;
	}

	pthread_mutex_lock(&m);
	struct hostent* he_tmp;
	he_tmp = ::gethostbyname(name);
	*he = *he_tmp;
	*he_errno = ::h_errno;
	pthread_mutex_unlock(&m);
	if (*he_errno) {
		log_err("gethostbyname() failed: %s (%d)", util::strerror(*he_errno), *he_errno);
		return -1;
	}

	return 0;
#endif // HAVE_GETHOSTBYNAME_R
}

/**
 *	thread safe inet_ntoa()
 */
int util::inet_ntoa(struct in_addr in, char* dst) {
	static pthread_mutex_t m;
	static bool is_mutex_initialized = false;

	if (is_mutex_initialized == false) {
		pthread_mutex_init(&m, NULL);
		is_mutex_initialized = true;
	}

	char* p;
	pthread_mutex_lock(&m);
	p = ::inet_ntoa(in);
	strcpy(dst, p);
	pthread_mutex_unlock(&m);

	return 0;
}

/**
 *	get my own fqdn
 */
int util::get_fqdn(string& fqdn) {
	char buf_hostname[BUFSIZ];

	if (gethostname(buf_hostname, sizeof(buf_hostname)) != 0) {
		log_warning("gethostname() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	struct hostent he;
	int e;
	if (util::gethostbyname(buf_hostname, &he, &e) != 0) {
		return -1;
	}

	fqdn = he.h_name;

	return 0;
}

/**
 *	get next word from buffer
 */
unsigned int util::next_word(const char* src, char* dst, unsigned int dst_len) {
	const char *p = src;
	char *q = dst;

	// sync w/ memcached behavior (cannot use isspace() here because memcached does not recognize '\t' and other space chars as ws)
	while (*p == ' ') {
		p++;
	}
	while (*p && *p != ' ' && *p != '\n' && static_cast<unsigned int>(p-src) < dst_len) {
		*q++ = *p++;
	}
	*q = '\0';

	return p-src;
}

/**
 *	get next digit(s) from buffer
 */
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

/**
 *	get realtime(?) (from memcached...)
 */
time_t util::realtime(time_t t) {
	if (t == 0) {
		return 0;
	}
	if (t <= util::max_realtime_delta) {
		return t + stats_object->get_timestamp();
	}
	return t;
}

/**
 *	base64 encode
 */
string util::base64_encode(const char* src, size_t src_size) {
	static const char base64_map[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	string r;
	uint8_t buf_binary[3];
	uint8_t buf_text[4];

	int i = 0;
	int j = 0;
	while (src_size--) {
		buf_binary[i++] = *(src++);
		if (i == 3) {
			buf_text[0] = (buf_binary[0] & 0xfc) >> 2;
			buf_text[1] = ((buf_binary[0] & 0x03) << 4) + ((buf_binary[1] & 0xf0) >> 4);
			buf_text[2] = ((buf_binary[1] & 0x0f) << 2) + ((buf_binary[2] & 0xc0) >> 6);
			buf_text[3] = buf_binary[2] & 0x3f;

			for(i = 0; i < 4; i++) {
				r += base64_map[buf_text[i]];
			}
			i = 0;
		}
	}

	if (i) {
		for (j = i; j < 3; j++) {
			buf_binary[j] = '\0';
		}
		buf_text[0] = (buf_binary[0] & 0xfc) >> 2;
		buf_text[1] = ((buf_binary[0] & 0x03) << 4) + ((buf_binary[1] & 0xf0) >> 4);
		buf_text[2] = ((buf_binary[1] & 0x0f) << 2) + ((buf_binary[2] & 0xc0) >> 6);
		buf_text[3] = buf_binary[2] & 0x3f;

		for (j = 0; j < (i + 1); j++) {
			r += base64_map[buf_text[j]];
		}

		while ((i++ < 3)) {
			r += '=';
		}
	}

	return r;
}

char* util::base64_decode(string src, size_t& dst_size) {
	static const char base64_map[] = {
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -1, -1, -2, -2, -1, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-1, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, 62, -2, -2, -2, 63,
		52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -2, -2, -2, -2, -2, -2,
		-2,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
		15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -2, -2, -2, -2, -2,
		-2, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
		41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
		-2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
	};

	int src_size = src.size();
	uint8_t buf_binary[3];
	uint8_t buf_text[4];

	char* dst = _new_ char[src_size];
	dst_size = 0;

	int i = 0;
	int j = 0;
	int tmp = 0;
	while (src_size-- && (src[tmp] != '=')) {
		buf_text[i++] = src[tmp];
		tmp++;
		if (i == 4) {
			for (i = 0; i < 4; i++) {
				buf_text[i] = base64_map[buf_text[i]];
			}

			buf_binary[0] = (buf_text[0] << 2) + ((buf_text[1] & 0x30) >> 4);
			buf_binary[1] = ((buf_text[1] & 0xf) << 4) + ((buf_text[2] & 0x3c) >> 2);
			buf_binary[2] = ((buf_text[2] & 0x3) << 6) + buf_text[3];

			for (i = 0; i < 3; i++) {
				dst[dst_size++] = buf_binary[i];
			}
			i = 0;
		}
	}

	if (i) {
		for (j = i; j < 4; j++) {
			buf_text[j] = 0;
		}

		for (j = 0; j < 4; j++) {
			buf_text[j] = base64_map[buf_text[j]];
		}

		buf_binary[0] = (buf_text[0] << 2) + ((buf_text[1] & 0x30) >> 4);
		buf_binary[1] = ((buf_text[1] & 0xf) << 4) + ((buf_text[2] & 0x3c) >> 2);
		buf_binary[2] = ((buf_text[2] & 0x3) << 6) + buf_text[3];

		for (j = 0; j < (i - 1); j++) {
			dst[dst_size++] = buf_binary[j];
		}
	}

	return dst;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
