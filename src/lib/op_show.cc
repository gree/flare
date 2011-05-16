/**
 *	op_show.cc
 *
 *	implementation of gree::flare::op_show
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *
 *	$Id$
 */

#include "op_show.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_show
 */
op_show::op_show(shared_connection c):
		op(c, "show"),
		_show_type(show_type_default) {
}

/**
 *	dtor for op_show
 */
op_show::~op_show() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_show::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (n > 0 && strcmp(q, "variables") == 0) {
		this->_show_type = show_type_variables;
	} else {
		this->_show_type = show_type_error;
	}
	log_debug("parameter=%s -> show_type=%d", p, this->_show_type);
	_delete_(p);

	if (this->_show_type == show_type_error) {
		return -1;
	}

	return 0;
}

int op_show::_run_server() {
	return 0;
}

int op_show::_send_show_variables() {
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
