/**
 *	op_parser_text_node.cc
 *	
 *	implementation of gree::flare::op_parser_text_node
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flared.h"
#include "op_parser_text_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_parser_text_node
 */
op_parser_text_node::op_parser_text_node(shared_connection c):
		op_parser_text(c) {
}

/**
 *	dtor for op_parser_text_node
 */
op_parser_text_node::~op_parser_text_node() {
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
op* op_parser_text_node::_determine_op(const char* first, const char* buf, int& consume) {
	op* r = NULL;
	if (strcmp(first, "get") == 0) {
		r = static_cast<op*>(_new_ op_get(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage())); 
	} else if (strcmp(first, "set") == 0) {
		r = static_cast<op*>(_new_ op_set(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage())); 
	} else if (strcmp(first, "delete") == 0) {
		r = static_cast<op*>(_new_ op_delete(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage())); 
	} else if (strcmp(first, "gets") == 0) {
		r = static_cast<op*>(_new_ op_gets(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage())); 
	} else if (strcmp(first, "ping") == 0) {
		r = static_cast<op*>(_new_ op_ping(this->_connection)); 
	} else if (strcmp(first, "stats") == 0) {
		r = static_cast<op*>(_new_ op_stats_node(this->_connection)); 
  } else if (strcmp(first, "node") == 0) {
		char second[BUFSIZ];
		consume += util::next_word(buf+consume, second, sizeof(second));
		log_debug("get second word (s=%s consume=%d)", second, consume);
		if (strcmp(second, "sync") == 0) {
			r = static_cast<op*>(_new_ op_node_sync(this->_connection, singleton<flared>::instance().get_cluster()));
		} else {
			r = static_cast<op*>(_new_ op_error(this->_connection));
		} 
	} else if (strcmp(first, "dump") == 0) {
		r = static_cast<op*>(_new_ op_dump(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()));
	} else if (strcmp(first, "flush_all") == 0) {
		r = static_cast<op*>(_new_ op_flush_all(this->_connection, singleton<flared>::instance().get_storage()));
	} else if (strcmp(first, "kill") == 0) {
		r = static_cast<op*>(_new_ op_kill(this->_connection, singleton<flared>::instance().get_thread_pool())); 
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
