/**
 *	server.cc
 *	
 *	implementation of gree::flare::server
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "server.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for server
 */
server::server():
		_port(0) {
}

/**
 *	dtor for server
 *	@access	public
 */
server::~server() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	setup server socket
 */
int server::listen(int port) {
	this->_port = port;

	// creating a socket
	this->_sock = socket(PF_INET, SOCK_STREAM, 0);
	if (this->_sock < 0) {
		log_err("socket() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	// socket option/attr
	int tmp = 1;
	if (setsockopt(this->_sock, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<char *>(&tmp), sizeof(tmp)) < 0) {
		log_err("setsockopt() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}
	if (setsockopt(this->_sock, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<char *>(&tmp), sizeof(tmp)) < 0) {
		log_err("setsockopt() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}
	int flag = fcntl(this->_sock, F_GETFL, 0);
	if (fcntl(this->_sock, F_SETFL, flag | O_NONBLOCK) < 0) {
		log_err("fcntl() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	// bind -> listen
	struct sockaddr_in addr;
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = INADDR_ANY;
	addr.sin_port = htons(this->_port);
	if (bind(this->_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		log_err("bind() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}
	int backlog = 8;    // see also tcp_max_syn_backlog
	if (::listen(this->_sock, backlog) < 0) {
		log_err("listen() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	log_info("server socket is ready for accept (port: %d)", this->_port);

	return 0;
}

/**
 *	wait for client request
 */
vector<shared_connection> server::wait() {
	vector<shared_connection> connection_list;

	fd_set fds;
	FD_ZERO(&fds);
	FD_SET(this->_sock, &fds);
	int n = select(FD_SETSIZE, &fds, 0, 0, 0);
	if (n <= 0) {
		if (errno != EINTR) {
			log_err("select() failed: %s (%d)", util::strerror(errno), errno);
		} else {
			log_notice("select() failed: %s (%d)", util::strerror(errno), errno);
		}
		return connection_list;
	}

	// accpet anyway
	struct sockaddr_in addr_remote;
	socklen_t addr_remote_len;
	int sock, j;
	for (j = 0; j < server::accept_retry_limit; j++) {
		addr_remote_len = sizeof(addr_remote);
		sock = accept(this->_sock, (struct sockaddr *)&addr_remote, &addr_remote_len);
		if (sock >= 0) {
			break;
		}
		if (errno == EAGAIN || errno == EINTR) {
			log_info("eagain or eintr -> retrying accept() (%d times left)", server::accept_retry_limit - j - 1);
			continue;
		} else {
			break;
		}
	}
	if (sock < 0) {
		log_err("accept() failed: %s (%d)", util::strerror(errno), errno);
		return connection_list;
	}
	int flag = fcntl(sock, F_GETFL, 0);
	if (fcntl(sock, F_SETFL, flag | O_NONBLOCK) < 0) {
		log_err("fcntl() failed: %s (%d)", util::strerror(errno), errno);
		::close(sock);	// try
		return connection_list;
	}
	log_info("socket accepted (fd=%d remote=%s)", sock, inet_ntoa(addr_remote.sin_addr));
	shared_connection c;
	try {
		c = shared_connection(new connection(sock, addr_remote));
	} catch (int e) {
		return connection_list;
	}
	connection_list.push_back(c);

	return connection_list;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
