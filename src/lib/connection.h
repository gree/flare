/**
 *	connection.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __NET_CONNECTION_H__
#define __NET_CONNECTION_H__

#include <poll.h>
#include <sys/un.h>

#include "net.h"

namespace gree {
namespace flare {

typedef class connection connection;
typedef shared_ptr<connection> shared_connection;

/**
 *	network connection class
 */
class connection : public net {
protected:
	sa_family_t					_addr_family;
	struct sockaddr_in	_addr_inet;
	struct sockaddr_un	_addr_unix;
	string							_host;
	int									_port;
	string							_path;
	int									_read_timeout;
	char*								_read_buf;
	char*								_read_buf_p;
	int									_read_buf_len;
	char*								_write_buf;
	int									_write_buf_len;
	int									_write_buf_chunk_size;
	int									_errno;

public:
	static int read_timeout;						// msec

	static const int connect_retry_limit = 8;
	static const int connect_retry_wait = 500*1000;	// usec
	static const int write_timeout = 10*1000;				// msec
	static const int chunk_size = 8192;

	connection();
	connection(int sock, struct sockaddr_in addr);
	connection(int sock, struct sockaddr_un addr);
	virtual ~connection();

	int open(string host, int port);
	int open() { return this->open(this->_host, this->_port); };
	int read(char** p, int expect_len, bool readline, bool& actual);
	int readline(char** p);
	int readsize(int expect_len, char** p);
	inline int push_back(char* p, int bufsiz) {
		log_debug("checking for lazy push back (bufsiz=%d, current=%d)", bufsiz, this->_read_buf_p - this->_read_buf);
		if (this->_read_buf && bufsiz <= (this->_read_buf_p - this->_read_buf)) {
			this->_read_buf_p -= bufsiz;
			this->_read_buf_len += bufsiz;
			return this->_read_buf_len;
		}

		char* tmp = _new_ char[this->_read_buf_len+bufsiz];
		memcpy(tmp, p, bufsiz);
		if (this->_read_buf) {
			memcpy(tmp+bufsiz, this->_read_buf_p, this->_read_buf_len);
			_delete_(this->_read_buf);
		}
		this->_read_buf = tmp;
		this->_read_buf_p = this->_read_buf;
		this->_read_buf_len += bufsiz;

		log_debug("successfully pushed back %d bytes (total buffer size=%d)", bufsiz, this->_read_buf_len);

		return this->_read_buf_len;
	};
	int write(const char *p, int bufsiz, bool buffered = false);
	int writeline(const char* p);
	int get_errno() { return this->_errno; };
	bool is_error() { return this->_errno != 0 ? true : false; };
	string get_host();
	int get_port();
	string get_path();
	int get_read_timeout() { return this->_read_timeout; };
	int set_read_timeout(int timeout) { this->_read_timeout = timeout; return 0; };

private:
	int _add_read_buf(char* p, int len);
	int _clear_read_buf();
	int _add_write_buf(const char* p, int len);
};

}	// namespace flare
}	// namespace gree

#endif // __NET_CONNECTION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
