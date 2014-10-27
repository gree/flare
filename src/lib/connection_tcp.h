/**
 *	connection_tcp.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef CONNECTION_TCP_H
#define CONNECTION_TCP_H

#include "connection.h"
#include "logger.h"
#include "util.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace gree {
namespace flare {

typedef class connection_tcp connection_tcp;
typedef boost::shared_ptr<connection_tcp> shared_connection_tcp;

/**
 *	network connection class
 */
class connection_tcp : public connection {
protected:
	sa_family_t					_addr_family;
	struct sockaddr_in	_addr_inet;
	struct sockaddr_un	_addr_unix;
	string							_host;
	int									_port;
	string							_path;
	int									_sock;
	int									_read_timeout;
	int									_errno;
	char*								_read_buf;
	char*								_read_buf_p;
	int									_read_buf_len;
	char*								_write_buf;
	int									_write_buf_len;
	int									_write_buf_chunk_size;
	int									_connect_retry_limit;
	int									_connect_retry_wait;	// usec

public:
	static int read_timeout;												// msec
	static const int connect_retry_limit = 8;
	static const int connect_retry_wait = 500*1000;	// usec
	static const int write_timeout = 10*1000;				// msec
	static const int chunk_size = 8192;

	connection_tcp(const std::string& host, int port);
	connection_tcp(int sock, struct sockaddr_in addr);
	connection_tcp(int sock, struct sockaddr_un addr);
	virtual ~connection_tcp();

	virtual int open() { return this->_open(this->get_host(), this->get_port()); };
	virtual int read(char** p, int expect_len, bool readline, bool& actual);
	virtual int readline(char** p);
	virtual int readsize(int expect_len, char** p);
	virtual inline int push_back(const char* p, int bufsiz) {
		log_debug("checking for lazy push back (bufsiz=%d, current=%d)", bufsiz, this->_read_buf_p - this->_read_buf);
		if (this->_read_buf && bufsiz <= (this->_read_buf_p - this->_read_buf)) {
			this->_read_buf_p -= bufsiz;
			this->_read_buf_len += bufsiz;
			return this->_read_buf_len;
		}

		char* tmp = new char[this->_read_buf_len+bufsiz];
		memcpy(tmp, p, bufsiz);
		if (this->_read_buf) {
			memcpy(tmp+bufsiz, this->_read_buf_p, this->_read_buf_len);
			delete[] this->_read_buf;
		}
		this->_read_buf = tmp;
		this->_read_buf_p = this->_read_buf;
		this->_read_buf_len += bufsiz;

		log_debug("successfully pushed back %d bytes (total buffer size=%d)", bufsiz, this->_read_buf_len);

		return this->_read_buf_len;
	};
	virtual int write(const char *p, int bufsiz, bool buffered = false);
	virtual int writeline(const char* p);
	
	string get_host() const;
	int get_port() const;
	string get_path() const;
	
	virtual int get_read_timeout() const { return this->_read_timeout; };
	virtual int set_read_timeout(int timeout) { this->_read_timeout = timeout; return 0; };
	virtual int get_connect_retry_limit() const { return this->_connect_retry_limit; };
	virtual int set_connect_retry_limit(int retry_limit) { this->_connect_retry_limit = retry_limit; return 0; };

	int get_errno() const { return this->_errno; };
	bool is_error() const { return this->_errno != 0 ? true : false; };

	virtual int close();
	virtual bool is_available() const { return this->_sock >= 0 ? true : false; };

	int set_tcp_nodelay(bool nodelay);
	int get_tcp_nodelay(bool& nodelay);

private:
	int _open(string host, int port);
	int _add_read_buf(char* p, int len);
	int _clear_read_buf();
	int _add_write_buf(const char* p, int len);
};

}	// namespace flare
}	// namespace gree

#endif // CONNECTION_TCP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
