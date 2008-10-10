/**
 *	net.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __NET_H__
#define __NET_H__

#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#include <boost/shared_ptr.hpp>

#include "mm.h"
#include "logger.h"
#include "util.h"

using namespace boost;

namespace gree {
namespace flare {

/**
 *	network i/o base class
 */
class net {
protected:
	int		_sock;

public:
	net();
	net(int sock);
	virtual ~net();

	int close();
	bool is_available() { return this->_sock >= 0 ? true : false; };
};

}	// namespace flare
}	// namespace gree

#endif // __NET_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
