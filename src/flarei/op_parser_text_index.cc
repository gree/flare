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
		r = static_cast<op*>(_new_ op_ping(this->_connection)); 
	} else if (strcmp(first, "stats") == 0) {
		r = static_cast<op*>(_new_ op_stats_index(this->_connection)); 
	} else if (strcmp(first, "node") == 0) {
		char second[BUFSIZ];
		consume += util::next_word(buf+consume, second, sizeof(second));
		log_debug("get second word (s=%s consume=%d)", second, consume); 
		if (strcmp(second, "add") == 0) {
			r = static_cast<op*>(_new_ op_node_add(this->_connection, singleton<flarei>::instance().get_cluster())); 
		} else if (strcmp(second, "remove") == 0) {
			r = static_cast<op*>(_new_ op_node_remove(this->_connection, singleton<flarei>::instance().get_cluster())); 
		} else if (strcmp(second, "role") == 0) {
			r = static_cast<op*>(_new_ op_node_role(this->_connection, singleton<flarei>::instance().get_cluster())); 
		} else if (strcmp(second, "state") == 0) {
			r = static_cast<op*>(_new_ op_node_state(this->_connection, singleton<flarei>::instance().get_cluster())); 
		} else {
			r = static_cast<op*>(_new_ op_error(this->_connection)); 
		}
	} else if (strcmp(first, "kill") == 0) {
		r = static_cast<op*>(_new_ op_kill(this->_connection, singleton<flarei>::instance().get_thread_pool())); 
	} else if (strcmp(first, "quit") == 0) {
		r = static_cast<op*>(_new_ op_quit(this->_connection)); 
	} else if (strcmp(first, "meta") == 0) {
		r = static_cast<op*>(_new_ op_meta(this->_connection, singleton<flarei>::instance().get_cluster())); 
	} else if (strcmp(first, "verbosity") == 0) {
		r = static_cast<op*>(_new_ op_verbosity(this->_connection)); 
	} else if (strcmp(first, "version") == 0) {
		r = static_cast<op*>(_new_ op_version(this->_connection)); 
	} else if (strcmp(first, "show") == 0) {
		r = static_cast<op*>(_new_ op_show_index(this->_connection)); 
	} else if (strcmp(first, "shutdown") == 0) {
		r = static_cast<op*>(_new_ op_shutdown(this->_connection, singleton<flarei>::instance().get_cluster()));
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
