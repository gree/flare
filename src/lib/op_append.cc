/**
 *	op_append.cc
 *
 *	implementation of gree::flare::op_append
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_append.h"
#include "binary_request_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_append
 */
op_append::op_append(shared_connection c, cluster* cl, storage* st):
		op_set(c, "append", binary_header::opcode_append, cl, st) {
	this->_behavior = storage::behavior_replace | storage::behavior_append;
}

/**
 *	ctor for op_append
 */
op_append::op_append(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_set(c, ident, opcode, cl, st) {
	this->_behavior = storage::behavior_replace | storage::behavior_append;
}

/**
 *	dtor for op_append
 */
op_append::~op_append() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_append::_parse_binary_request(const binary_request_header& header, const char* body) {
	if (header.get_extras_length() == _binary_request_required_extras_length
			&& this->_entry.parse(header, body) == 0) {
		shared_byte data(new uint8_t[this->_entry.size]);
		memcpy(data.get(), body + header.get_extras_length() + header.get_key_length(), this->_entry.size);
		this->_entry.data = data;
		return 0;
	}
	return -1;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
