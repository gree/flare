/**
 *	connection_tcp.cc
 *	
 *	implementation of gree::flare::connection_tcp
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "app.h"
#include "connection_tcp.h"

namespace gree {
namespace flare {

int connection_tcp::read_timeout = 10*60*1000;

// {{{ ctor/dtor
/**
 *	ctor for connection_tcp
 */
connection_tcp::connection_tcp(const std::string& host, int port):
		connection(),
		_addr_family(AF_INET),
		_addr_inet(),
		_addr_unix(),
		_host(host),
		_port(port),
		_path(""),
		_sock(-1),
		_read_timeout(read_timeout),
		_errno(0),
		_read_buf(NULL),
		_read_buf_p(NULL),
		_read_buf_len(0),
		_write_buf(NULL),
		_write_buf_len(0),
		_write_buf_chunk_size(0),
		_connect_retry_limit(connection_tcp::connect_retry_limit),
		_connect_retry_wait(connection_tcp::connect_retry_wait) {
}

/**
 *	ctor for connection_tcp
 */
connection_tcp::connection_tcp(int sock, struct sockaddr_in addr):
		connection(),
		_addr_family(AF_INET),
		_addr_inet(addr),
		_addr_unix(),
		_host(""),
		_port(-1),
		_path(""),
		_sock(sock),
		_read_timeout(read_timeout),
		_errno(0),
		_read_buf(NULL),
		_read_buf_p(NULL),
		_read_buf_len(0),
		_write_buf(NULL),
		_write_buf_len(0),
		_write_buf_chunk_size(0),
		_connect_retry_limit(connection_tcp::connect_retry_limit),
		_connect_retry_wait(connection_tcp::connect_retry_wait) {
}

/**
 *	ctor for connection_tcp
 */
connection_tcp::connection_tcp(int sock, struct sockaddr_un addr):
		connection(),
		_addr_family(AF_UNIX),
		_addr_inet(),
		_addr_unix(addr),
		_host(""),
		_port(-1),
		_path(""),
		_sock(sock),
		_read_timeout(read_timeout),
		_errno(0),
		_read_buf(NULL),
		_read_buf_p(NULL),
		_read_buf_len(0),
		_write_buf(NULL),
		_write_buf_len(0),
		_write_buf_chunk_size(0),
		_connect_retry_limit(connection_tcp::connect_retry_limit),
		_connect_retry_wait(connection_tcp::connect_retry_wait) {
}

/**
 *	dtor for connection_tcp
 */
connection_tcp::~connection_tcp() {
	if (this->_sock >= 0) {
		if (::close(this->_sock) < 0) {
			log_err("close() for socket failed: %s (errno:%d fd:%d)", strerror(errno), errno, this->_sock);
		} else {
			log_debug("socket closed (%d)", this->_sock);
		}
	}
	delete[] this->_read_buf;
	this->_read_buf = NULL;
	delete[] this->_write_buf;
	this->_write_buf = NULL;
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	open tcp connection_tcp
 */
int connection_tcp::_open(string host, int port) {
	this->_errno = 0;
	log_debug("connecting to %s:%d", host.c_str(), port);

	this->_sock = socket(AF_INET, SOCK_STREAM, 0);
	if (this->_sock < 0) {
		log_err("socket() failed: %s (%d)", util::strerror(errno), errno);
		this->_errno = errno;
		return -1;
	}

	this->_addr_family = AF_INET;

	if (util::gethostbyname(host, port, this->_addr_family, this->_addr_inet, this->_errno) < 0) {
		this->close();
		return -1;
	}

	int i;
	for (i = 0; i < (this->_connect_retry_limit+1); i++) {
		if (connect(this->_sock, (struct sockaddr*)&this->_addr_inet, sizeof(this->_addr_inet)) < 0) {
			log_warning("connect() failed: %s (%d) -> wait for %d usec", util::strerror(errno), errno, this->_connect_retry_wait);
			usleep(this->_connect_retry_wait);
			continue;
		}
		break;
	}
	if (i == (this->_connect_retry_limit+1)) {
		log_err("connect() failed", -1);
		this->_errno = errno;
		this->close();
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
int connection_tcp::read(char** p, int expect_len, bool readline, bool& actual) {
	if (this->_sock < 0) {
		log_warning("connection seems to be already closed (sock=%d)", this->_sock);
		return -1;
	}

	this->_errno = 0;

	// internal buffer handling
	if (readline && this->_read_buf_len > 0) {
		log_debug("reading from internal buffer (mode=readline, read_buf_len=%d)", this->_read_buf_len);
		int len = 0;
		char* q = static_cast<char*>(memchr(this->_read_buf_p, '\n', this->_read_buf_len));
		if (q) {
			len = q-this->_read_buf_p+1;
			*p = new char[len+1];
			memcpy(*p, this->_read_buf_p, len);
			*((*p)+len) = '\0';
			this->_read_buf_p += len;
			this->_read_buf_len -= len;
			log_debug("new line char found [%s] (len=%d, read_buf_len=%d)", *p, len, this->_read_buf_len);

			// skip clearing read buffer (lazy deletion)
		} else {
			*p = new char[this->_read_buf_len];
			memcpy(*p, this->_read_buf_p, this->_read_buf_len);
			len = this->_read_buf_len;
			log_debug("no new line char found (read_buf_len=%d) -> flushing buffers", this->_read_buf_len);
			this->_clear_read_buf();
		}
		actual = false;

		return len;
	} else if (this->_read_buf_len > 0) {
		log_debug("reading from internal buffer (mode=binary, read_buf_len=%d, expect_len)", this->_read_buf_len, expect_len);
		int len = 0;
		if (expect_len > 0 && this->_read_buf_len > expect_len) {
			*p = new char[expect_len];
			memcpy(*p, this->_read_buf_p, expect_len);
			len = expect_len;
			this->_read_buf_p += expect_len;
			this->_read_buf_len -= expect_len;
		} else {
			*p = new char[this->_read_buf_len];
			memcpy(*p, this->_read_buf_p, this->_read_buf_len);
			len = this->_read_buf_len;
			this->_clear_read_buf();
		}
		actual = false;

		return len;
	}

	struct pollfd ufds = {0};
	ufds.fd = this->_sock;
	ufds.events = POLLIN | POLLPRI;

	*p = NULL;
	int bufsiz = -1;
	int len = 0;
	actual = true;
	do {
		int n = poll(&ufds, 1, this->_read_timeout);
		if (n == 0) {
			log_info("poll() timed out (%0.4f sec)", this->_read_timeout / 1000.0);
			this->_errno = -1;
			delete[] *p;
			*p = NULL;
			return -1;
		}
		if (n < 0 || !(ufds.revents & (POLLIN | POLLPRI))) {
			this->_errno = errno;
#ifdef POLLRDHUP
			if (ufds.revents & POLLRDHUP) {  // since Linux 2.6.17
				log_notice("poll() failed: %s (%d) -> peer closed connection", util::strerror(errno), errno);
				this->close();
				delete[] *p;
				*p = NULL;
				return -1;
			}
#endif
			if (errno != EINTR) {
				log_err("poll() failed: %s (%d) -> closing socket", util::strerror(errno), errno);
				this->close();
			} else {
				log_notice("poll() failed: %s (%d)", util::strerror(errno), errno);
			}
			delete[] *p;
			*p = NULL;
			return -1;
		}

		if (bufsiz < 0) {
			// initial loop
			if (expect_len > 1 * 1024) {
				bufsiz = expect_len;
			} else {
				if (::ioctl(this->_sock, FIONREAD, &bufsiz)) {
					log_err("ioctl() failed: %s (%d) -> closing socket", util::strerror(errno), errno);
					this->close();
					this->_errno = errno;
					delete[] *p;
					*p = NULL;
					return -1;
				}
			}
			log_debug("trying to read %d bytes", bufsiz);
			*p = new char[bufsiz];
		}

		int tmp = ::read(this->_sock, (*p) + len, bufsiz - len);
		if (tmp == 0) {
			// peer seems to have closed the connection
			log_info("peer seems to have closed the connection (read 0 byte) -> closing socket", 0);
			delete[] *p;
			*p = NULL;
			this->close();
			this->_errno = -2;
			return -2;
		} else if ((len+tmp) >= bufsiz) {
			log_debug("read %d bytes (expect %d bytes) -> complete", len+tmp, bufsiz);
			if (expect_len > 0 && (len+tmp) > expect_len && bufsiz < (1 * 1024) && this->_read_buf == NULL) {
				this->_add_read_buf(*p, len+tmp);
				this->_read_buf_len -= expect_len;
				this->_read_buf_p += expect_len;

				stats_object->add_bytes_read(tmp);
				return expect_len;
			}
		} else if (tmp < 0) {
			if (errno == EAGAIN) {
				log_info("read() failed: %s (%d)", util::strerror(errno), errno);
				continue;
			}
			log_err("read() failed: %s (%d)", util::strerror(errno), errno);
			delete[] *p;
			*p = NULL;
			if (errno == EINTR) {
				return 0;
			}
			log_err("-> closing socket", 0);
			this->close();
			return -1;
		} else if ((len+tmp) < bufsiz) {
			// worth continuing
			log_info("expect %d bytes but read %d byes (total %d bytes) -> continue processing", bufsiz, tmp, len);
		}

		stats_object->add_bytes_read(tmp);
		len += tmp;
	} while (len < bufsiz);

	return len;
}

/**
 *	read 1 line (till \n) from peer
 *
 *	- caller should delete *p if this method is successfully done (returned > 0)
 *	- "\r\n" is converted to "\n"
 *	- returned data is NULL-terminated
 */
int connection_tcp::readline(char** p) {
	int r_len = 0;
	char* r = NULL;
	char* r_tmp = NULL;
	for (;;) {
		char* tmp = NULL;
		bool actual;
		int len = this->read(&tmp, -1, true, actual);
		if (len < 0) {
			if (r) {
				log_err("discarding intermediate buffers (%d bytes)", r_len);
				delete[] r;
			}
			return len;
		}

		// directly using read buffer (disirable case)
		if (actual == false && r_len == 0 && tmp[len-1] == '\n') {
			log_debug("seems that we can use internal buffer directly", 0);
			r_len = len;
			if (len > 1 && tmp[len-2] == '\r') {
				tmp[len-2] = '\n';
				tmp[len-1] = '\0';
				r_len--;
			}
			r = tmp;
			break;
		}

		char* q = static_cast<char*>(memchr(tmp, '\n', len));
		if (q) {
			char* w = q;
			if ((w-tmp) > 0 && *(w-1) == '\r') {
				w--;
			} else if ((w-tmp) == 0 && r_len > 0 && r[r_len-1] == '\r') {
				r_len -= 1;
			}
			int tmp_len = w-tmp+1;
			r_tmp = new char[r_len+tmp_len+1];
			if (r) {
				memcpy(r_tmp, r, r_len);
				delete[] r;
			}
			memcpy(r_tmp+r_len, tmp, tmp_len);
			*(r_tmp+r_len+tmp_len-1) = '\n';
			*(r_tmp+r_len+tmp_len) = '\0';
			r_len += tmp_len;
			r = r_tmp;

			if ((len - (q-tmp+1)) > 0) {
				this->_add_read_buf(tmp+(q-tmp+1), len-(q-tmp+1));
			}
			delete[] tmp;
			break;
		} else {
			// not yet
			r_tmp = new char[r_len+len];
			if (r) {
				memcpy(r_tmp, r, r_len);
				delete[] r;
			}
			memcpy(r_tmp+r_len, tmp, len);
			r_len += len;
			r = r_tmp;
		}
		delete[] tmp;
	}

	*p = r;
	log_debug("p=[%s] len=%d", *p, r_len);

	return r_len;
}

/**
 *	read specifized size from peer
 *
 *	- caller should delete *p if this method is successfully done (returned > 0)
 */
int connection_tcp::readsize(int expect_len, char** p) {
	char* data = NULL;
	char* data_tmp = NULL;
	int data_len = 0;
	log_debug("ready to read %d bytes", expect_len);

	while (data_len < expect_len) {
		char* tmp = NULL;
		bool actual;
		int tmp_len = this->read(&tmp, expect_len - data_len, false, actual);
		if (tmp_len < 0) {
			delete[] data;
			return tmp_len;
		} else if (data_len == 0 && tmp_len == expect_len) {
			log_debug("successfully read %d bytes (desirable)", tmp_len);
			*p = tmp;
			return tmp_len;
		} else if (data == NULL) {
			data = new char[expect_len];
			data_tmp = data;
		}

		if (data_len+tmp_len >= expect_len) {
			int diff_len = expect_len - data_len;
			memcpy(data_tmp, tmp, diff_len);
			data_tmp += diff_len;
			data_len = data_tmp - data;

			// add extra data to internal read buffer
			if (tmp_len-diff_len > 0) {
				this->_add_read_buf(tmp+diff_len, tmp_len-diff_len);
			}
		} else {
			memcpy(data_tmp, tmp, tmp_len);
			data_tmp += tmp_len;
			data_len = data_tmp - data;
		}
		delete[] tmp;
	}

	*p = data;
	log_debug("successfully read %d bytes", data_len);

	return data_len;
}

/**
 *	write data to peer
 */
int connection_tcp::write(const char* p, int bufsiz, bool buffered) {
	if (this->_sock < 0) {
		log_warning("connection seems to be already closed (sock=%d)", this->_sock);
		return -1;
	}

	if (buffered) {
		this->_add_write_buf(p, bufsiz);
		return bufsiz;
	}

	if (this->_write_buf != NULL) {
		this->_add_write_buf(p, bufsiz);
		p = this->_write_buf;
		bufsiz = this->_write_buf_len;
	}

	this->_errno = 0;

	int written = 0;
	while (written < bufsiz) {
		int len = ::write(this->_sock, p+written, bufsiz-written);
		if (len < 0) {
			if (errno == EAGAIN) {
				log_info("write() failed: %s (%d) -> poll()", util::strerror(errno), errno);

				struct pollfd ufds;
				ufds.fd = this->_sock;
				ufds.events = POLLOUT;
				int n = poll(&ufds, 1, connection_tcp::write_timeout);
				if (n == 0) {
					log_info("poll() timed out (%0.4f sec)", connection_tcp::write_timeout / 1000.0);
					continue;
				} else if (n < 0 || !(ufds.revents & (POLLOUT))) {
					if (errno == EINTR) {
						log_info("poll() failed: %s (%d)", util::strerror(errno), errno);
						continue;
					}

					// other errors are treated as write() error
				} else {
					log_debug("poll() -> ready to write", 0);
					continue;
				}
			} else if (errno == EINTR) {
				log_info("write() failed: %s (%d)", util::strerror(errno), errno);
				continue;
			}
			log_err("write() failed: %s (%d) -> closing socket", util::strerror(errno), errno);
			this->close();
			this->_errno = errno;

			// delete buffer...anyway
			delete[] this->_write_buf;
			this->_write_buf = NULL;
			this->_write_buf_len = this->_write_buf_chunk_size = 0;

			return -1;
		} else if (len == 0) {
			log_notice("write %d bytes (total %d bytes) -> perhaps no more write operation is available", len, written);
			break;
		}
		stats_object->add_bytes_written(len);
		written += len;
		if (written >= bufsiz) {
			log_debug("write %d bytes (total %d bytes) -> complete", len, written);
			break;
		} else {
			log_info("expect %d bytes but write %d bytes (total %d bytes) -> continue processing", bufsiz, len, written);
		}
	}

	delete[] this->_write_buf;
	this->_write_buf = NULL;
	this->_write_buf_len = this->_write_buf_chunk_size = 0;

	return written;
}

/**
 *	write "\r\n" terminated string to peer
 */
int connection_tcp::writeline(const char* p) {
	int len = strlen(p);
	log_debug("p=[%s] len=%d", p, len);
	char* q = new char[len+3];
	memcpy(q, p, len);
	memcpy(q+len, line_delimiter, 3);
	len += 2;

	int m = 0;
	int n = 0;
	int r = 0;
	do {
		r = this->write(q+n, len-n);
		if (r < 0) {
			delete[] q;
			return r;
		}
		n += r;
		m++;
	} while(n < len && m < 8);
	delete[] q;
	if (m == 8) {
		return -1;
	}

	return n;
}

string connection_tcp::get_host() const {
	if (this->_host.empty() == false) {
		return this->_host;
	} else if (this->_addr_family == AF_UNIX) {
		return "";
	}

	char buf[BUFSIZ];
	util::inet_ntoa(this->_addr_inet.sin_addr, buf);

	string s = buf;
	return s;
}

int connection_tcp::get_port() const {
	if (this->_port >= 0) {
		return this->_port;
	} else if (this->_addr_family == AF_UNIX) {
		return 0;
	}

	return ntohs(this->_addr_inet.sin_port);
}

string connection_tcp::get_path() const {
	if (this->_path.empty() == false) {
		return this->_path;
	} else if (this->_addr_family != AF_UNIX) {
		return "";
	}

	return this->_addr_unix.sun_path;
}

/**
 *	close connection
 */
int connection_tcp::close() {
	if (this->_sock >= 0) {
		if (::close(this->_sock) < 0) {
			log_err("close() failed: %s (%d)", strerror(errno), errno);
		} else {
			log_debug("socket closed(%d)", this->_sock);
		}
		this->_sock = -1;
	} else {
		log_info("close() called but socket seems to be already closed [%d]", this->_sock);
	}
	return 0;
}

/**
 *	setsockopt TCP_NODELAY
 */
int connection_tcp::set_tcp_nodelay(bool nodelay) {
	if (this->_sock < 0) {
		log_warning("connection seems to be already closed (sock=%d)", this->_sock);
		return -1;
	}
	if (this->_addr_family != AF_UNIX) {
		int flag = nodelay?1:0;
		if (setsockopt(this->_sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<char*>(&flag), sizeof(flag)) < 0) {
			log_err("setsockopt() failed: %s (%d) - TCP_NODELAY", util::strerror(errno), errno);
			return -1;
		}
	}
	return 0;
}

/**
 *	getsockopt TCP_NODELAY
 */
int connection_tcp::get_tcp_nodelay(bool& nodelay) {
	if (this->_sock < 0) {
		log_warning("connection seems to be already closed (sock=%d)", this->_sock);
		return -1;
	}
	if (this->_addr_family != AF_UNIX) {
		int flag = 0;
		socklen_t flaglen = sizeof(flag);
		if (getsockopt(this->_sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<char*>(&flag), &flaglen) < 0) {
			log_err("getsockopt() failed: %s (%d) - TCP_NODELAY", util::strerror(errno), errno);
			return -1;
		}
		nodelay = flag?true:false;
	} else {
		nodelay = false;
	}
	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
/**
 *	append data to internal read buffer
 */
int connection_tcp::_add_read_buf(char* p, int len) {
	if (this->_read_buf && this->_read_buf_len <= 0) {
		this->_clear_read_buf();
	}

	char* tmp = new char[this->_read_buf_len+len];
	if (this->_read_buf_len > 0) {
		memcpy(tmp, this->_read_buf_p, this->_read_buf_len);
		delete[] this->_read_buf;
	}
	memcpy(tmp+this->_read_buf_len, p, len);

	this->_read_buf = tmp;
	this->_read_buf_p = this->_read_buf;
	this->_read_buf_len += len;

	return this->_read_buf_len;
}

int connection_tcp::_clear_read_buf() {
	log_debug("clearing internal read buffer (read_buf_len=%d)", this->_read_buf_len);
	delete[] this->_read_buf;
	this->_read_buf = NULL;
	this->_read_buf_p = NULL;
	this->_read_buf_len = 0;

	return 0;
}

/**
 *	append data to internal write buffer
 */
int connection_tcp::_add_write_buf(const char* p, int len) {
	int new_chunk_size = (this->_write_buf_len + len) / connection_tcp::chunk_size + 1;
	log_debug("adding to internal write buffer (current_len=%d, current_chunk_size=%d, write_len=%d, new_chunk_size=%d)", this->_write_buf_len, this->_write_buf_chunk_size, len, new_chunk_size);
	if (new_chunk_size > this->_write_buf_chunk_size) {
		char* tmp = new char[new_chunk_size * connection_tcp::chunk_size];
		if (this->_write_buf != NULL) {
			memcpy(tmp, this->_write_buf, this->_write_buf_len);
			delete[] this->_write_buf;
		}
		this->_write_buf = tmp;
	}
	memcpy(this->_write_buf+this->_write_buf_len, p, len);
	this->_write_buf_len += len;
	this->_write_buf_chunk_size = new_chunk_size;

	return this->_write_buf_len;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
