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
