/**
 *	net.cc
 *	
 *	implementation of gree::flare::net
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "net.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for net
 */
net::net():
		_sock(-1) {
}

/**
 *	ctor for net
 */
net::net(int sock):
		_sock(sock) {
}

/**
 *	dtor for net
 */
net::~net() {
	if (this->_sock >= 0) {
		if (::close(this->_sock) < 0) {
			log_err("close() for socket failed: %s (errno:%d fd:%d)", strerror(errno), errno, this->_sock);
		} else {
			log_debug("socket closed (%d)", this->_sock);
		}
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	close connection
 */
int net::close() {
	int r = 0;

	if (this->_sock >= 0) {
		if (::close(this->_sock) < 0) {
			log_err("close() failed: %s (%d)", strerror(errno), errno);
			r = -1;
		} else {
			log_debug("socket closed(%d)", this->_sock);
		}
		this->_sock = -1;
	} else {
		log_info("close() called but socket seems to be already closed [%d]", this->_sock);
	}

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
