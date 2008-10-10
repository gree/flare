/**
 *	connection.cc
 *	
 *	implementation of gree::flare::connection
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "app.h"
#include "connection.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for connection
 */
connection::connection():
		_host(""),
		_port(-1),
		_read_buf(NULL),
		_read_buf_len(0) {
}

/**
 *	ctor for connection
 */
connection::connection(int sock, struct sockaddr_in addr):
		net(sock),
		_addr(addr),
		_host(""),
		_port(-1),
		_read_buf(NULL),
		_read_buf_len(0) {
}

/**
 *	dtor for connection
 */
connection::~connection() {
	if (this->_read_buf) {
		_delete_(this->_read_buf);
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	open connection
 */
int connection::open(string host, int port) {
	this->_errno = 0;
	log_debug("connecting to %s:%d", host.c_str(), port);

	this->_sock = socket(AF_INET, SOCK_STREAM, 0);
	if (this->_sock < 0) {
		log_err("socket() failed: %s (%d)", util::strerror(errno), errno);
		this->_errno = errno;
		return -1;
	}

	struct hostent he;
	struct hostent* he_result;
	char he_buf[2048];
	int he_errno;
	if (gethostbyname_r(host.c_str(), &he, he_buf, sizeof(he_buf), &he_result, &he_errno) < 0) {
		log_err("gethostbyname_r() failed: %s (%d)", util::strerror(he_errno), he_errno);
		this->_errno = errno;
		return -1;
	}

	memset(&this->_addr, 0, sizeof(this->_addr));
	this->_addr.sin_family = AF_INET;
	this->_addr.sin_port = htons(port);
	memcpy(&this->_addr.sin_addr, he.h_addr, he.h_length);
	int i;
	for (i = 0; i < connection::connect_retry_limit; i++) {
		if (connect(this->_sock, (struct sockaddr*)&this->_addr, sizeof(this->_addr)) < 0) {
			log_warning("connect() failed: %s (%d) -> wait for %d usec", util::strerror(errno), errno, connection::connect_retry_wait);
			usleep(connection::connect_retry_wait);
			continue;
		}
		break;
	}
	if (i == connection::connect_retry_limit) {
		log_err("connect() failed", -1);
		this->_errno = errno;
		return -1;
	}

	this->_host = host;
	this->_port = port;

	return 0;
}

/**
 *	read chunk data from peer
 *	
 *	- caller should delete *p if this method is successfully done (returned > 0)
 */
int connection::read(char** p) {
	this->_errno = 0;

	if (this->_read_buf_len > 0) {
		*p = this->_read_buf;
		int len = this->_read_buf_len;
		log_debug("reading from internal buffer (%d bytes)", len);

		this->_read_buf = NULL;
		this->_read_buf_len = 0;
		return len;
	}

	fd_set fds;
	timeval tv;
	FD_ZERO(&fds);
	FD_SET(this->_sock, &fds);
	tv.tv_sec = connection::read_timeout / 1000;
	tv.tv_usec = 0;
	int n = select(FD_SETSIZE, &fds, 0, 0, &tv);
	if (n == 0) {
		log_info("select() timed out (%d sec)", connection::read_timeout / 1000);
		this->_errno = -1;
		return -1;
	}
	if (n < 0) {
		if (errno != EINTR) {
			log_err("select() failed: %s (%d)", util::strerror(errno), errno);
		} else {
			log_notice("select() failed: %s (%d)", util::strerror(errno), errno);
		}
		this->_errno = errno;
		return -1;
	}
	if (!FD_ISSET(this->_sock, &fds)) {
		log_info("select() retruns > 0 value but no socket available", 0);
		this->_errno = -1;
		return -1;
	}

	int bufsiz;
	if (::ioctl(this->_sock, FIONREAD, &bufsiz)) {
		log_err("ioctl() failed: %s (%d)", util::strerror(errno), errno);
		this->_errno = errno;
		return -1;
	}

	*p = _new_ char[bufsiz];
	int len = ::read(this->_sock, *p, bufsiz);
	if (len == 0) {
		// peer seems to close connection
		log_info("peer seems to close connection (read 0 byte)", 0);
		_delete_(*p);
		*p = NULL;
		this->_errno = -2;
		return -2;
	} else if (len == bufsiz) {
		log_debug("read %d bytes", len);
	} else if (len < 0) {
		log_err("read() failed: %s (%d)", util::strerror(errno), errno);
		_delete_(*p);
		*p = NULL;
		if (errno == EAGAIN) {
			return 0;
		} else if (errno == EINTR) {
			return 0;
		}
		return -1;
	} else if (len < bufsiz) {
		// something wrong but worth continuing
		log_info("expect %d bytes but read %d byes -> continue processing", bufsiz, len);
	}

	stats_object->add_bytes_read(len);

	return len;
}

/**
 *	read 1 line (till \n) from peer
 *
 *	- caller should delete *p if this method is successfully done (returned > 0)
 *	- "\r\n" is converted to "\n"
 *	- returned data is NULL-terminated
 */
int connection::readline(char** p) {
	int r_len = 0;
	char* r = NULL;
	char* r_tmp = NULL;
	for (;;) {
		char* tmp = NULL;
		int len = this->read(&tmp);
		if (len < 0) {
			if (r_len > 0) {
				log_err("discarding intermediate buffers (%d bytes)", r_len);
			}
			if (r) {
				_delete_(r);
			}
			return len;
		}

		char* q = static_cast<char*>(memchr(tmp, '\n', len));
		if (q) {
			char* w = q;
			if ((w-tmp) > 0 && *(w-1) == '\r') {
				w--;
			}
			int tmp_len = w-tmp+1;
			r_tmp = _new_ char[r_len+tmp_len+1];
			if (r) {
				memcpy(r_tmp, r, r_len);
				_delete_(r);
			}
			memcpy(r_tmp+r_len, tmp, tmp_len);
			*(r_tmp+r_len+tmp_len-1) = '\n';
			*(r_tmp+r_len+tmp_len) = '\0';
			r_len += tmp_len;
			r = r_tmp;

			this->_add_read_buf(tmp+(q-tmp+1), len-(q-tmp+1));
			_delete_(tmp);
			break;
		} else {
			// not yet
			r_tmp = _new_ char[r_len+len];
			if (r) {
				memcpy(r_tmp, r, r_len);
				_delete_(r);
			}
			memcpy(r_tmp+r_len, tmp, len);
			r_len += len;
			r = r_tmp;
		}
		_delete_(tmp);
	}

	*p = r;
	log_debug("p=%s len=%d", *p, r_len);

	return r_len;
}

/**
 *	read specifized size from peer
 *
 *	- caller should delete *p if this method is successfully done (returned > 0)
 */
int connection::readsize(int expect_len, char** p) {
	char* data = NULL;
	int data_len = 0;
	log_debug("ready to read %d bytes", expect_len);
	while (data_len < expect_len) {
		char* tmp;
		int tmp_len = this->read(&tmp);
		if (tmp_len < 0) {
			return tmp_len;
		}

		if (data_len+tmp_len >= expect_len) {
			int diff_len = expect_len - data_len;
			diff_len = diff_len > tmp_len ? tmp_len : diff_len;
			char* data_tmp = _new_ char[data_len+diff_len];
			if (data) {
				memcpy(data_tmp, data, data_len);
				_delete_(data);
			}
			memcpy(data_tmp+data_len, tmp, diff_len);
			data = data_tmp;
			data_len += diff_len;

			// add extra data to internal read buffer
			if (tmp_len-diff_len > 0) {
				this->_add_read_buf(tmp+diff_len, tmp_len-diff_len);
			}
		} else {
			char* data_tmp = _new_ char[data_len+tmp_len];
			if (data) {
				memcpy(data_tmp, data, data_len);
				_delete_(data);
			}
			memcpy(data_tmp+data_len, tmp, tmp_len);
			data = data_tmp;
			data_len += tmp_len;
		}
		_delete_(tmp);
	}

	*p = data;
	log_debug("successfully read %d bytes", data_len);

	return data_len;
}

/**
 *	push back read buffer
 *
 *	- data is always push back at *top* of read buffer, so caller should be carefull of order
 */
int connection::push_back(char* p, int bufsiz) {
	char* tmp = _new_ char[this->_read_buf_len+bufsiz];
	memcpy(tmp, p, bufsiz);
	if (this->_read_buf) {
		memcpy(tmp+bufsiz, this->_read_buf, this->_read_buf_len);
		_delete_(this->_read_buf);
	}
	this->_read_buf_len += bufsiz;
	this->_read_buf = tmp;

	log_debug("successfully pushed back %d bytes (total buffer size=%d)", bufsiz, this->_read_buf_len);

	return this->_read_buf_len;
}

/**
 *	write data to peer
 */
int connection::write(const char* p, int bufsiz) {
	this->_errno = 0;

	int len = ::write(this->_sock, p, bufsiz);
	if (len < 0) {
		log_err("write() failed: %s (%d)", util::strerror(errno), errno);
		if (errno == EAGAIN || errno == EINTR) {
			return 0;
		}
		this->_errno = errno;
		return -1;
	}
	if (len == bufsiz) {
		log_debug("write %d bytes", len);
	} else {
		log_info("expect %d bytes but read %d byes -> continue processing", bufsiz, len);
	}

	stats_object->add_bytes_written(len);

	return len;
}

/**
 *	write "\r\n" terminated string to peer
 */
int connection::writeline(const char* p) {
	int len = strlen(p);
	char* q = _new_ char[len+3];
	memcpy(q, p, len);
	memcpy(q+len, line_delimiter, 3);
	len += 2;

	int m = 0;
	int n = 0;
	int r = 0;
	do {
		r = this->write(q+n, len-n);
		if (r < 0) {
			_delete_(q);
			return r;
		}
		n += r;
		m++;
	} while(n < len && m < 8);
	_delete_(q);
	if (m == 8) {
		return -1;
	}

	return n;
}

string connection::get_host() {
	if (this->_host.empty() == false) {
		return this->_host;
	}

	char buf[BUFSIZ];
	util::inet_ntoa(this->_addr.sin_addr, buf);

	string s = buf;
	return s;
}

int connection::get_port() {
	if (this->_port >= 0) {
		return this->_port;
	}

	return ntohs(this->_addr.sin_port);
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
/**
 *	append data to internal read buffer
 *
 *	- ring buffer make me faster:)
 */
int connection::_add_read_buf(char* p, int len) {
	char* tmp = _new_ char[this->_read_buf_len+len];
	if (this->_read_buf) {
		memcpy(tmp, this->_read_buf, this->_read_buf_len);
		_delete_(this->_read_buf);
	}
	memcpy(tmp+this->_read_buf_len, p, len);
	this->_read_buf_len += len;
	this->_read_buf = tmp;

	return this->_read_buf_len;
}
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
