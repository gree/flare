/**
 *	server.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef NET_SERVER_H
#define NET_SERVER_H

#include "config.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#ifdef HAVE_EPOLL
#include <sys/epoll.h>
#endif

#ifdef HAVE_KQUEUE
#include <sys/event.h>
#endif

#include "connection_tcp.h"

namespace gree {
namespace flare {

/**
 *	network server class
 *
 *	@todo	support multi-port-listening (w/ epoll, kequeue, etc...)
 */
class server {
public:
	static const int max_listen_socket = 256;
	static const int accept_retry_limit = 16;

protected:
	int		_listen_socket[max_listen_socket];
	int		_listen_socket_index;
#ifdef HAVE_EPOLL
	int		_epoll_socket;
#endif
#ifdef HAVE_KQUEUE
	int		_kqueue_socket;
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
	vector<shared_connection_tcp> wait();

protected:
	int _set_listen_socket_option(int sock, int domain = PF_INET);
#ifdef HAVE_EPOLL
	int _add_epoll_socket(int sock);
#endif
#ifdef HAVE_KQUEUE
	int	_add_kqueue_socket(int sock);
#endif
};

}	// namespace flare
}	// namespace gree

#endif // NET_SERVER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
