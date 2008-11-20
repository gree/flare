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
	struct sockaddr_in	_addr;
	string							_host;
	int									_port;
	int									_read_timeout;
	char*								_read_buf;
	uint32_t						_read_buf_len;
	char*								_write_buf;
	uint32_t						_write_buf_len;
	uint32_t						_write_buf_chunk_size;
	int									_errno;

public:
	static const int connect_retry_limit = 8;
	static const int connect_retry_wait = 500*1000;		// usec
	static const int read_timeout = 10*60*1000;				// msec
	static const int write_retry_limit = 8;
	static const int write_retry_wait = 500*1000;			// usec
	static const int chunk_size = 8192;

	connection();
	connection(int sock, struct sockaddr_in addr);
	virtual ~connection();

	int open(string host, int port);
	int open() { return this->open(this->_host, this->_port); };
	int read(char** p);
	int readline(char** p);
	int readsize(int expect_len, char** p);
	int push_back(char* p, int bufsiz);
	int write(const char *p, int bufsiz, bool buffered = false);
	int writeline(const char* p);
	int get_errno() { return this->_errno; };
	bool is_error() { return this->_errno != 0 ? true : false; };
	string get_host();
	int get_port();
	int get_read_timeout() { return this->_read_timeout; };
	int set_read_timeout(int timeout) { this->_read_timeout = timeout; return 0; };

private:
	int _add_read_buf(char* p, int len);
	int _add_write_buf(const char* p, int len);
};

}	// namespace flare
}	// namespace gree

#endif // __NET_CONNECTION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
