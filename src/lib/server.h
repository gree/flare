/**
 *	server.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __NET_SERVER_H__
#define __NET_SERVER_H__

#include "config.h"

#include <sys/types.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netinet/tcp.h>

#ifdef HAVE_EPOLL
#include <sys/epoll.h>
#endif

#include "connection.h"

namespace gree {
namespace flare {

/**
 *	network server class
 *
 *	@todo	support multi-port-listening (w/ epoll, kequeue, etc...)
 */
class server : public net {
public:
	static const int max_listen_socket = 256;
	static const int accept_retry_limit = 16;

protected:
	int		_listen_socket[max_listen_socket];
	int		_listen_socket_index;
#ifdef HAVE_EPOLL
	int		_epoll_socket;
#endif
	int		_back_log;

public:
	server();
	virtual ~server();

	int get_back_log() { return this->_back_log; };
	int set_back_log(int back_log) { this->_back_log = back_log; return 0; };

	int close();
	int listen(int port);
	int listen(string uds);
	vector<shared_connection> wait();

protected:
	int _set_listen_socket_option(int sock, int domain = PF_INET);
#ifdef HAVE_EPOLL
	int _add_epoll_socket(int sock);
#endif
};

}	// namespace flare
}	// namespace gree

#endif // __NET_SERVER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
