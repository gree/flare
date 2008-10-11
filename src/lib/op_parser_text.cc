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

	// first string
	char first[1024];
	int consume = util::next_word(buf, first, sizeof(first));
	log_debug("get first word (s=%s consume=%d)", first, consume);

	// optimized order:)
	op* r = this->_determine_op(first, buf, consume);

	this->_connection->push_back(buf+consume, buf_len-consume);
	_delete_(buf);

	return r;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
