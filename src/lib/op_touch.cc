/**
 *	op_touch.cc
 *
 *	implementation of gree::flare::op_touch
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#include "op_touch.h"
#include "binary_request_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_touch
 */
op_touch::op_touch(shared_connection c, cluster* cl, storage* st):
		op_set(c, "touch", binary_header::opcode_touch, cl, st) {
	this->_behavior = storage::behavior_touch;
}

/**
 *	ctor for op_touch
 */
op_touch::op_touch(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_set(c, ident, opcode, cl, st) {
	this->_behavior = storage::behavior_touch;
}

/**
 *	dtor for op_touch
 */
op_touch::~op_touch() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_touch::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_entry.parse(p, storage::parse_type_touch) < 0) {
		delete[] p;
		return -1;
	}
	delete[] p;

	switch (this->_entry.option) {
		case storage::option_none:
		case storage::option_noreply:
			return 0;
		default:
			// Only the "noreply" option is accepted
			return -1;
	}
}

int op_touch::_parse_binary_request(const binary_request_header& header, const char* body) {
	if (body
			&& header.get_extras_length() == _binary_request_required_extras_length
			&& this->_entry.parse(header, body) == 0) {
		this->_entry.expire = util::realtime(ntohl(*(reinterpret_cast<const uint32_t*>(body))));
		return 0;
	}
	return -1;
}

int op_touch::_run_client(storage::entry& e) {
	string proxy_ident = this->_get_proxy_ident();
	int request_len = proxy_ident.size() + e.key.size() + BUFSIZ;
	char* request = new char[request_len];
	int offset = snprintf(request, request_len, "%s%s %s %ld", proxy_ident.c_str(), this->get_ident().c_str(), e.key.c_str(), e.expire);
	if (e.option & storage::option_noreply) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_noreply).c_str());
	}
	offset += snprintf(request+offset, request_len-offset, "%s", line_delimiter);
	if (this->_connection->write(request, offset) < 0) {
		delete[] request;
		return -1;
	}
	delete[] request;

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
