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
#include "connection_tcp.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for server
 */
server::server():
		_listen_socket_index(0),
#ifdef HAVE_EPOLL
		_epoll_socket(-1),
#endif
#ifdef HAVE_KQUEUE
		_kqueue_socket(-1),
#endif
		_back_log(SOMAXCONN) {
}

/**
 *	dtor for server
 */
server::~server() {
	if (this->close() < 0) {
		// ...
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	close listening socket(s)
 */
int server::close() {
	int r = 0;

	struct sockaddr addr;
	struct sockaddr_un* addr_unix = NULL;

#ifdef HAVE_EPOLL
	if (this->_epoll_socket >= 0) {
		if (::close(this->_epoll_socket) < 0) {
			log_err("close() failed: %s (%d) (sock=epoll)", util::strerror(errno), errno);
		}
		this->_epoll_socket = -1;
	}
#endif

#ifdef HAVE_KQUEUE
	if (this->_kqueue_socket >= 0) {
		if (::close(this->_kqueue_socket) < 0) {
			log_err("close() failed: %s (%d) (sock=kqueue)", util::strerror(errno), errno);
		}
		this->_kqueue_socket = -1;
	}
#endif

	for (int i = 0; i < this->_listen_socket_index; i++) {
		int sock = this->_listen_socket[i];

		if (sock >= 0) {
			// this will be cost but i do not care about it in this situation
			socklen_t addr_len = sizeof(addr);
			if (getsockname(sock, &addr, &addr_len) < 0) {
				log_notice("getsockname() failed: %s (%d) -> assuming sa_family = AF_INET", util::strerror(errno), errno);
				addr.sa_family = AF_INET;
			}

			if (::close(sock) < 0) {
				r = -1;
				log_err("close() failed: %s (%d) (index=%d)", util::strerror(errno), errno, i);
			} else {
				log_debug("socket closed (sock=%d, index=%d)", sock, i);
			}

			if (addr.sa_family == AF_UNIX) {
				addr_unix = reinterpret_cast<struct sockaddr_un*>(&addr);
				if (unlink(addr_unix->sun_path) < 0) {
					log_err("unlink() failed: %s (%d) (index=%d)", util::strerror(errno), errno, i);
				} else {
					log_debug("unix domain socket removed (path=%s)", addr_unix->sun_path);
				}
			}

			this->_listen_socket[i] = -1;
		} else {
			log_info("close() called but socket seems to be already closed (sock=%d, index=%d)", sock, i);
		}
	}
	this->_listen_socket_index = 0;

	return r;
}

/**
 *	setup server socket
 */
int server::listen(int port) {
	if (this->_listen_socket_index >= this->max_listen_socket) {
		log_err("listen socket limit exceeded (max_listen_socket=%d)", this->max_listen_socket);
		return -1;
	}

	// creating a socket
	int sock = socket(PF_INET, SOCK_STREAM, 0);
	if (sock < 0) {
		log_err("socket() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	// socket option/attr
	if (this->_set_listen_socket_option(sock) < 0) {
		::close(sock);
		return -1;
	}

	// bind -> listen
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = INADDR_ANY;
	addr.sin_port = htons(port);
	if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		::close(sock);
		log_err("bind() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}
	if (::listen(sock, this->_back_log) < 0) {
		::close(sock);
		log_err("listen() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	this->_listen_socket[this->_listen_socket_index] = sock;
	this->_listen_socket_index++;

	log_info("server socket (type=inet) is ready to accept (port: %d)", port);

#ifdef HAVE_EPOLL
	if (this->_add_epoll_socket(sock) < 0) {
		return -1;
	}
#endif

#ifdef HAVE_KQUEUE
	if (this->_add_kqueue_socket(sock) < 0) {
		return -1;
	}
#endif

	return 0;
}

/**
 *	setup server socket
 */
int server::listen(string uds) {
	if (this->_listen_socket_index >= this->max_listen_socket) {
		log_err("listen socket limit exceeded (max_listen_socket=%d)", this->max_listen_socket);
		return -1;
	}

	// creating a socket
	int sock = socket(PF_UNIX, SOCK_STREAM, 0);
	if (sock < 0) {
		log_err("socket() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	// socket option/attr
	if (this->_set_listen_socket_option(sock, PF_UNIX) < 0) {
		::close(sock);
		return -1;
	}

	// bind -> listen
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, uds.c_str(), sizeof(addr.sun_path)-1);
	if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		::close(sock);
		log_err("bind() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}
	if (::listen(sock, this->_back_log) < 0) {
		::close(sock);
		log_err("listen() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	if (chmod(addr.sun_path, 0777) < 0) {
		::close(sock);
		log_err("chmod() failed: %s (%d) (path=%s)", util::strerror(errno), errno, addr.sun_path);
		return -1;
	} else {
		log_debug("setting permission of unix domain socket as world writable (path=%s)", addr.sun_path);
	}

	this->_listen_socket[this->_listen_socket_index] = sock;
	this->_listen_socket_index++;

	log_info("server socket (type=unix) is ready to accept (path: %s)", uds.c_str());

#ifdef HAVE_EPOLL
	if (this->_add_epoll_socket(sock) < 0) {
		return -1;
	}
#endif

#ifdef HAVE_KQUEUE
	if (this->_add_kqueue_socket(sock) < 0) {
		return -1;
	}
#endif

	return 0;
}

/**
 *	wait for client request
 */
vector<shared_connection_tcp> server::wait() {
	vector<shared_connection_tcp> connection_list;

#if defined(HAVE_EPOLL)
	const char* poll_type = "epoll_wait";		// just for logging
	struct epoll_event ev_list[this->max_listen_socket];
	int n = epoll_wait(this->_epoll_socket, ev_list, this->max_listen_socket, -1);
#elif defined(HAVE_KQUEUE)
	const char* poll_type = "kqueue_wait";		// just for logging
	struct kevent kev[this->max_listen_socket];
	int n = kevent(this->_kqueue_socket, NULL, 0, kev, this->max_listen_socket, NULL);
#else
	const char* poll_type = "select";		// just for logging
	fd_set fds;
	FD_ZERO(&fds);
	for (int i = 0; i < this->_listen_socket_index; i++) {
		FD_SET(this->_listen_socket[i], &fds);
	}
	int n = select(FD_SETSIZE, &fds, 0, 0, 0);
#endif
	if (n <= 0) {
		if (errno != EINTR) {
			log_err("%s() failed: %s (%d)", poll_type, util::strerror(errno), errno);
		} else {
			log_notice("%s() failed: %s (%d)", poll_type, util::strerror(errno), errno);
		}
		return connection_list;
	}

	// accpet anyway
#if defined(HAVE_EPOLL)
	for (int i = 0; i < n; i++) {
		int listen_socket = ev_list[i].data.fd;
#elif defined(HAVE_KQUEUE)
	for (int i = 0; i < n; i++) {
		int listen_socket = kev[i].ident;
#else
	for (int i = 0; i < this->_listen_socket_index; i++) {
		if (!FD_ISSET(this->_listen_socket[i], &fds)) {
			continue;
		}
		int listen_socket = this->_listen_socket[i];
#endif

		struct sockaddr addr;
		struct sockaddr_in* addr_inet = NULL;
		struct sockaddr_un* addr_unix = NULL;
		socklen_t addr_len;
		int sock, j;
		for (j = 0; j < server::accept_retry_limit; j++) {
			addr_len = sizeof(addr);
			sock = accept(listen_socket, &addr, &addr_len);
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

		if (addr.sa_family == AF_UNIX) {
			addr_unix = reinterpret_cast<sockaddr_un*>(&addr);
		} else {
			addr_inet = reinterpret_cast<sockaddr_in*>(&addr);
		}

		// socket option/attr
		int flag = fcntl(sock, F_GETFL, 0);
		if (fcntl(sock, F_SETFL, flag | O_NONBLOCK) < 0) {
			log_err("fcntl() failed: %s (%d)", util::strerror(errno), errno);
			::close(sock);	// try
			return connection_list;
		}

		flag = 1;
		if (setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<char*>(&flag), sizeof(flag)) < 0) {
			log_err("setsockopt() failed: %s (%d) - SO_KEEPALIVE", util::strerror(errno), errno);
			::close(sock);
			return connection_list;
		}

		log_info("socket accepted (fd=%d remote=%s)", sock, addr.sa_family == AF_UNIX ? "unix domain socket" : inet_ntoa(addr_inet->sin_addr));
		shared_connection_tcp c;
		try {
			if (addr.sa_family == AF_UNIX) {
				c = shared_connection_tcp(new connection_tcp(sock, *addr_unix));
			} else {
				c = shared_connection_tcp(new connection_tcp(sock, *addr_inet));
				if (c->set_tcp_nodelay(true) < 0) {
					throw -1;
				}
			}
		} catch (int e) {
			return connection_list;
		}
		connection_list.push_back(c);
	}

	return connection_list;
}
// }}}

// {{{ protected methods
/**
 *	setup sever socket option
 */
int server::_set_listen_socket_option(int sock, int domain) {
	int tmp = 1;

	if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<char *>(&tmp), sizeof(tmp)) < 0) {
		log_err("setsockopt() for SO_REUSEADDR failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	if (setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<char *>(&tmp), sizeof(tmp)) < 0) {
		log_err("setsockopt() SO_KEEPALIVE failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	if (domain != PF_UNIX) {
		if (setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<char*>(&tmp), sizeof(tmp)) < 0) {
			log_err("setsockopt() TCP_NODELAY failed: %s (%d)", util::strerror(errno), errno);
			return -1;
		}
	}

	int flag = fcntl(sock, F_GETFL, 0);
	if (fcntl(sock, F_SETFL, flag | O_NONBLOCK) < 0) {
		log_err("fcntl() failed: %s (%d)", util::strerror(errno), errno);
		return -1;
	}

	return 0;
}

#ifdef HAVE_EPOLL
/**
 *	add listen socket to epoll
 */
int server::_add_epoll_socket(int sock) {
	if (this->_epoll_socket < 0) {
		this->_epoll_socket = epoll_create(this->max_listen_socket);
		if (this->_epoll_socket < 0) {
			log_err("epoll_create() failed: %s (%d)", util::strerror(errno), errno);
			return -1;
		}
	}

	struct epoll_event ev;
	memset(&ev, 0, sizeof(ev));

	// we can use edge trigger here but use leve trigger for safe for a while...
	ev.events = EPOLLIN;
	ev.data.fd = sock;
	if (epoll_ctl(this->_epoll_socket, EPOLL_CTL_ADD, sock, &ev) < 0) {
		log_err("epoll_ctl() failed: %s (%d) (sock=%d)", util::strerror(errno), errno, sock);
		return -1;
	} else {
		log_debug("added listen socket to epoll (epoll_socket=%d, listen_socket=%d)", this->_epoll_socket, sock);
	}

	return 0;
}
#endif

#ifdef HAVE_KQUEUE
/**
 *  add listen socket to kqueue
 */
int server::_add_kqueue_socket(int sock) {
	if (this->_kqueue_socket < 0) {
		this->_kqueue_socket = kqueue();
		if (this->_kqueue_socket < 0) {
			log_err("kqueue() failed: %s (%s)", util::strerror(errno), errno);
			return -1;
		}
	}

	struct kevent kev;
	EV_SET(&kev, sock, EVFILT_READ, EV_ADD, 0, 0, NULL);
	if (kevent(this->_kqueue_socket, &kev, 1, NULL, 0, NULL) < 0 ) {
		log_err("kevent() failed: %s (%d) (sock=%d)", util::strerror(errno), errno, sock);
		return -1;
	} else {
		log_debug("added listen socket to kevent (kqueue_socket=%d, listen_socket=%d)", this->_kqueue_socket, sock);
	}

	return 0;
}
#endif
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
