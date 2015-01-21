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
 *	connection_iostream.cc
 *	
 *	implementation of gree::flare::connection_iostream
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *	
 *	$Id$
 */
#include "connection_iostream.h"

#include <app.h>
#include <binary_request_header.h>
#include <binary_response_header.h>

#include <sstream>

namespace gree {
namespace flare {

// {{{ ctor/dtor
connection_iostream::connection_iostream(std::iostream* istream, std::iostream* ostream):
	_istream(boost::shared_ptr<std::iostream>(istream)),
	_ostream(boost::shared_ptr<std::iostream>(ostream)) {
}

connection_sstream::connection_sstream(const std::string& string):
	connection_iostream(new stringstream(string), new stringstream()) {
}

connection_sstream::connection_sstream(const binary_request_header& header, const char* body):
	connection_iostream(new stringstream(), new stringstream()) {
	_istream->write(header.get_raw_data(), header.get_raw_size());
	if (header.get_total_body_length() && body) {
		_istream->write(body, header.get_total_body_length());
	}
}

connection_sstream::connection_sstream(const binary_response_header& header, const char* body):
	connection_iostream(new stringstream(), new stringstream()) {
	_istream->write(header.get_raw_data(), header.get_raw_size());
	if (header.get_total_body_length() && body) {
		_istream->write(body, header.get_total_body_length());
	}
}

connection_fstream::connection_fstream(const std::string& input_filename, const std::string& output_filename):
	connection_iostream(new fstream(input_filename.c_str()), new fstream(output_filename.c_str())) {
}

connection_iostream::~connection_iostream() { }

connection_sstream::~connection_sstream() { }

connection_fstream::~connection_fstream() { }
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	read chunk data from peer
 *	
 *	- caller should delete *p if this method is successfully done (returned > 0)
 */
int connection_iostream::read(char** p, int expect_len, bool readline, bool& actual) {
	int n = 0;
	if (expect_len && _istream) {
		if (readline) {
			std::string line;
			getline(*_istream, line);
			n = line.size() + 1;
			char* buffer = new char[n + 1];
			memcpy(buffer, line.c_str(), n);
			buffer[n - 1] = '\n';
			buffer[n] = 0;
			*p = buffer;
		}
		else {
			char* buffer = new char[expect_len + 1];
			_istream->read(buffer, expect_len);
			n = _istream->gcount();
			if (n < expect_len) {
				n = -1;
				delete[] buffer;
			} else {
				buffer[expect_len] = 0;
				*p = buffer;
			}
		}
	}
	actual = false;
	return n;
}

/**
 *	read 1 line (till \n) from peer
 *
 *	- caller should delete *p if this method is successfully done (returned > 0)
 *	- "\r\n" is converted to "\n"
 *	- returned data is NULL-terminated
 */
int connection_iostream::readline(char** p) {
	bool dummy;
	int n = read(p, -1 , true, dummy);
	if (n > 2 && (*p)[n - 2] == '\r')
	{
		(*p)[n - 2] = '\n';
		(*p)[n - 1] = 0;
		--n;
	}
	return n;
}

/**
 *	read specifized size from peer
 *
 *	- caller should delete *p if this method is successfully done (returned > 0)
 */
int connection_iostream::readsize(int expect_len, char** p) {
	bool dummy;
	return read(p, expect_len, false, dummy);
}

/**
 *	put back characters into the stream
 */
int connection_iostream::push_back(const char* p, int bufsiz) {
	if (_istream->tellg() >= bufsiz) {
		_istream->seekg(-bufsiz, ios::cur);
	}
	else {
		for (int i = bufsiz - 1; i >= 0; --i)
			_istream->putback(p[i]);
	}

	// getting buffer length of iostream isn't easy.
	return 0;
}

/**
 *	write data to peer
 */
int connection_iostream::write(const char* p, int bufsiz, bool buffered) {
	_ostream->write(p, bufsiz);
	return bufsiz;
}

/**
 *	write "\r\n" terminated string to peer
 */
int connection_iostream::writeline(const char* p) {
	(*_ostream) << p << line_delimiter;
	int len = strlen(p);
	return len + 2;
}

string connection_sstream::get_output() const {
	return static_cast<const stringstream&>(*_ostream).str();
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
