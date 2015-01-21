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
 *	op_parser_text_index.cc
 *	
 *	implementation of gree::flare::op_parser_text_index
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flarei.h"
#include "op_parser_text_index.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_parser_text_index
 */
op_parser_text_index::op_parser_text_index(shared_connection c):
		op_parser_text(c) {
}

/**
 *	dtor for op_parser_text_index
 */
op_parser_text_index::~op_parser_text_index() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
/**
 *	determine op
 */
op* op_parser_text_index::_determine_op(const char* first, const char* buf, int& consume) {
	op* r = NULL;
	if (strcmp(first, "ping") == 0) {
		r = new op_ping(this->_connection); 
	} else if (strcmp(first, "stats") == 0) {
		r = new op_stats_index(this->_connection); 
	} else if (strcmp(first, "node") == 0) {
		char second[BUFSIZ];
		consume += util::next_word(buf+consume, second, sizeof(second));
		log_debug("get second word (s=%s consume=%d)", second, consume); 
		if (strcmp(second, "add") == 0) {
			r = new op_node_add(this->_connection, singleton<flarei>::instance().get_cluster()); 
		} else if (strcmp(second, "remove") == 0) {
			r = new op_node_remove(this->_connection, singleton<flarei>::instance().get_cluster()); 
		} else if (strcmp(second, "role") == 0) {
			r = new op_node_role(this->_connection, singleton<flarei>::instance().get_cluster()); 
		} else if (strcmp(second, "state") == 0) {
			r = new op_node_state(this->_connection, singleton<flarei>::instance().get_cluster()); 
		} else {
			r = new op_error(this->_connection); 
		}
	} else if (strcmp(first, "kill") == 0) {
		r = new op_kill(this->_connection, singleton<flarei>::instance().get_thread_pool()); 
	} else if (strcmp(first, "quit") == 0) {
		r = new op_quit(this->_connection); 
	} else if (strcmp(first, "meta") == 0) {
		r = new op_meta(this->_connection, singleton<flarei>::instance().get_cluster()); 
	} else if (strcmp(first, "verbosity") == 0) {
		r = new op_verbosity(this->_connection); 
	} else if (strcmp(first, "version") == 0) {
		r = new op_version(this->_connection); 
	} else if (strcmp(first, "show") == 0) {
		r = new op_show_index(this->_connection); 
	} else if (strcmp(first, "shutdown") == 0) {
		r = new op_shutdown(this->_connection, singleton<flarei>::instance().get_cluster());
	} else {
		r = new op_error(this->_connection); 
	}

	return r;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
