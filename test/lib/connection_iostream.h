/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
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

protected:
	connection_iostream(std::iostream* istream, std::iostream* ostream);
	boost::shared_ptr<std::iostream> const _istream;
	boost::shared_ptr<std::iostream> const _ostream;
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
