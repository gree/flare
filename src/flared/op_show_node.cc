/**
 *	op_show_node.cc
 *	
 *	implementation of gree::flare::op_show_node
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *	
 *	$Id$
 */
#include "op_show_node.h"
#include "show_node.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_show_node
 */
op_show_node::op_show_node(shared_connection c):
		op_show(c) {
}

/**
 *	dtor for op_show_node
 */
op_show_node::~op_show_node() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_show_node::_parse_text_server_parameters() {
	int r = op_show::_parse_text_server_parameters();

	return r;
}

int op_show_node::_run_server() {
	switch (this->_show_type) {
	case show_type_variables:
		this->_send_show_variables();
		break;
	default:
		break;
	}
	this->_send_result(result_end);

	return 0;
}

int op_show_node::_send_show_variables() {
	ostringstream s;

	vector<string> lines = show_node::lines();
	vector<string>::iterator line = lines.begin();
	while (true) {
		s << *line;
		line++;
		if (line == lines.end()) {
			break;
		}
		s << line_delimiter;
	}

	this->_connection->writeline(s.str().c_str());

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
