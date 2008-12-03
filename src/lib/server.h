/**
 *	server.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __NET_SERVER_H__
#define __NET_SERVER_H__

#include <netinet/tcp.h>

#include "connection.h"

namespace gree {
namespace flare {

/**
 *	network server class
 *
 *	@todo	support multi-port-listening (w/ epoll, kequeue, etc...)
 */
class server : public net {
protected:
	int		_port;

public:
	static const int accept_retry_limit = 16;

	server();
	virtual ~server();

	int get_port() { return this->_port; };

	int listen(int port);
	vector<shared_connection> wait();
};

}	// namespace flare
}	// namespace gree

#endif // __NET_SERVER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
