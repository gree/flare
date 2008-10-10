/**
 *	op_parser_text_manager.cc
 *	
 *	implementation of gree::flare::op_parser_text_manager
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flarem.h"
#include "op_parser_text_manager.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_parser_text_manager
 */
op_parser_text_manager::op_parser_text_manager(shared_connection c):
		op_parser_text(c) {
}

/**
 *	dtor for op_parser_text_manager
 */
op_parser_text_manager::~op_parser_text_manager() {
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
op* op_parser_text_manager::_determine_op(const char* first, const char* buf) {
	op* r = NULL;
	if (strcmp(first, "ping") == 0) {
		r = static_cast<op*>(_new_ op_ping(this->_connection)); 
	} else if (strcmp(first, "stats") == 0) {
		r = static_cast<op*>(_new_ op_stats_manager(this->_connection)); 
	} else if (strcmp(first, "kill") == 0) {
		r = static_cast<op*>(_new_ op_kill(this->_connection, singleton<flarem>::instance().get_thread_pool())); 
	} else if (strcmp(first, "quit") == 0) {
		r = static_cast<op*>(_new_ op_quit(this->_connection)); 
	} else if (strcmp(first, "version") == 0) {
		r = static_cast<op*>(_new_ op_version(this->_connection)); 
	} else {
		r = static_cast<op*>(_new_ op_error(this->_connection)); 
	}

	return r;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent

