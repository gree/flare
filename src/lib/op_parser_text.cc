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
 *	op_parser_text.cc
 *
 *	implementation of gree::flare::op_parser_text
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_parser_text.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_parser_text
 */
op_parser_text::op_parser_text(shared_connection c):
		op_parser(c) {
}

/**
 *	dtor for op_parser_text
 */
op_parser_text::~op_parser_text() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
op* op_parser_text::parse_server() {
	char *buf;
	int buf_len = this->_connection->readline(&buf);
	if (buf_len < 0) {
		return NULL;
	}

	// see if proxy request or not
	int consume = 0;
	char* proxy = NULL;
	if (buf[0] == '<') {
		char* p = strchr(buf, '>');
		if (p != NULL) {
			consume = p-buf+1;
			proxy = new char[p-buf];
			strncpy(proxy, buf+1, p-buf-1);
			proxy[p-buf-1] = '\0';
		}
	}

	// first string
	char first[1024];
	consume += util::next_word(buf+consume, first, sizeof(first));
	log_debug("get first word (s=%s consume=%d)", first, consume);

	op* r = this->_determine_op(first, buf, consume);
	this->_connection->push_back(buf+consume, buf_len-consume);
	if (proxy != NULL) {
		r->set_proxy(string(proxy));
		delete[] proxy;
	}
	delete[] buf;

	return r;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
