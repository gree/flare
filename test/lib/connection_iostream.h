/**
 *	connection_iostream.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */
#ifndef CONNECTION_IOSTREAM_H
#define CONNECTION_IOSTREAM_H

#include <connection.h>

#include <iostream>

namespace gree {
namespace flare {

// Forward declarations
class binary_request_header;
class binary_response_header;

/**
 *	string connection class
 */
class connection_iostream : public connection {
public:
	virtual ~connection_iostream();

	virtual int open() { return 0; }
	virtual int close() { return 0; }
	virtual bool is_available() const { return true; }

	virtual int read(char** p, int expect_len, bool readline, bool& actual);
	virtual int readline(char** p);
	virtual int readsize(int expect_len, char** p);
	virtual int push_back(const char* p, int bufsiz);
	virtual int write(const char *p, int bufsiz, bool buffered = false);
	virtual int writeline(const char* p);

	// note: timeout and retry are not implemented
	virtual int get_read_timeout() const { return this->_read_timeout; };
	virtual int set_read_timeout(int timeout) { this->_read_timeout = timeout; return 0; };
	virtual int get_connect_retry_limit() const { return this->_connect_retry_limit; };
	virtual int set_connect_retry_limit(int retry_limit) { this->_connect_retry_limit = retry_limit; return 0; };

protected:
	connection_iostream(std::iostream* istream, std::iostream* ostream);
	boost::shared_ptr<std::iostream> const _istream;
	boost::shared_ptr<std::iostream> const _ostream;
	int _read_timeout;
	int	_connect_retry_limit;
};

class connection_sstream : public connection_iostream {
public:
	connection_sstream(const std::string& string);
	connection_sstream(const binary_request_header& header, const char* body = NULL);
	connection_sstream(const binary_response_header& header, const char* body = NULL);
	virtual ~connection_sstream();

	std::string get_output() const;
};

class connection_fstream : public connection_iostream {
public:
	connection_fstream(const std::string& input_filename,
			const std::string& output_filename);
	virtual ~connection_fstream();
};

}	// namespace flare
}	// namespace gree

#endif // CONNECTION_IOSTREAM_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
