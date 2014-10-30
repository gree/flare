/**
 *	connection.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef CONNECTION_H
#define CONNECTION_H

#include <string>

#include <boost/shared_ptr.hpp>

using std::string;

namespace gree {
namespace flare {

typedef class connection connection;
typedef boost::shared_ptr<connection> shared_connection;

/**
 *	network connection class
 */
class connection {
public:
	connection() { }
	virtual ~connection() { }

	virtual int open() = 0;
	virtual int close() = 0;
	virtual bool is_available() const = 0;

	virtual int read(char** p, int expect_len, bool readline, bool& actual) = 0;
	virtual int readline(char** p) = 0;
	virtual int readsize(int expect_len, char** p) = 0;
	virtual int push_back(const char* p, int bufsiz) = 0;
	virtual int write(const char *p, int bufsiz, bool buffered = false) = 0;
	virtual int writeline(const char* p) = 0;
};

}	// namespace flare
}	// namespace gree

#endif // CONNECTION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
