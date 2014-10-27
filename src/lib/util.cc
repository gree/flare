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
	static map<pthread_t, boost::shared_ptr<string> > msg_map;
	static pthread_mutex_t mutex_msg_map = PTHREAD_MUTEX_INITIALIZER; 
	char buf[BUFSIZ];

#ifdef HAVE_GNU_STRERROR_R
	char* p = strerror_r(e, buf, sizeof(buf));
	boost::shared_ptr<string> ptr(new string(p));
#else
	strerror_r(e, buf, sizeof(buf));
	boost::shared_ptr<string> ptr(new string(buf));
#endif // HAVE_GNU_STRERROR_R

	pthread_mutex_lock(&mutex_msg_map);
	msg_map[pthread_self()] = ptr;
	pthread_mutex_unlock(&mutex_msg_map);

	return msg_map[pthread_self()]->c_str();
}

/**
 *	hstrerror
 */
const char* util::hstrerror(int e) {
	const char* msg = "unknown error";
	switch (e) {
	case HOST_NOT_FOUND:
		msg = "host is unknown";
		break;
	case NO_ADDRESS:
		msg = "name is valid but does not have an address";
		break;
	case NO_RECOVERY:
		msg = "non-recoverable name server error";
		break;
	case TRY_AGAIN:
		msg = "temporary error";
		break;
	}
	return msg;
}

/**
 *	thread safe gethostbyname()
 */
int util::gethostbyname(const std::string& host, int port, sa_family_t family, sockaddr_in& output, int& gai_errno, std::string* canonname) {
	std::ostringstream port_os;
	port_os << port;
	struct addrinfo hints, *res;
	memset(&hints, 0, sizeof(hints));
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_family = family;
	if (canonname) {
		hints.ai_flags |= AI_CANONNAME;
	}
	gai_errno = getaddrinfo(host.c_str(), port_os.str().c_str(), &hints, &res);
	if (gai_errno) {
		log_err("getaddrinfo() failed: %s (%d)", gai_strerror(gai_errno), gai_errno);
		return -1;
	}
	memcpy(&output, res->ai_addr, res->ai_addrlen);
	if (canonname && res->ai_canonname) {
		canonname->assign(res->ai_canonname, strlen(res->ai_canonname));
	}
	freeaddrinfo(res);
	return 0;
}

/**
 *	thread safe inet_ntoa()
 */
int util::inet_ntoa(struct in_addr in, char* dst) {
	static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;

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

	struct sockaddr_in dummy;
	int gai_errno;
	if (util::gethostbyname(buf_hostname, 0, AF_INET, dummy, gai_errno, &fqdn) != 0) {
		return -1;
	}

	return 0;
}

/**
 *	get network address
 */
in_addr_t util::inet_addr(const char *cp, const uint32_t netmask) {
	in_addr_t addr = ::inet_addr(cp);
	if (addr == INADDR_NONE) {
		sockaddr_in sockaddr;
		int gai_errno;
		if (util::gethostbyname(cp, 0, AF_INET, sockaddr, gai_errno) != 0) {
			return INADDR_NONE;
		}
		addr = sockaddr.sin_addr.s_addr;
	}
	return (addr & static_cast<in_addr_t>(netmask));
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
	uint8_t buf_binary[3] = {0};
	uint8_t buf_text[4];

	char* dst = new char[src_size];
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
