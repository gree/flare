/**
 *	op_gat.cc
 *
 *	implementation of gree::flare::op_gat
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#include "op_gat.h"
#include "binary_response_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_gat
 */
op_gat::op_gat(shared_connection c, cluster* cl, storage* st):
		op_touch(c, "gat", binary_header::opcode_gat, cl, st) {
}

/**
 *	ctor for op_gat
 */
op_gat::op_gat(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_touch(c, ident, opcode, cl, st) {
}

/**
 *	dtor for op_gat
 */
op_gat::~op_gat() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_gat::_parse_text_client_parameters(storage::entry& e) {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (strcmp(p, "NOT_FOUND\n") == 0) {
		this->_result = result_not_found;
		delete[] p;
		return 0;
	}

	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (strcmp(q, "VALUE") != 0) {
		log_debug("invalid token (q=%s)", q);
		delete[] p;
		return -1;
	}

	storage::entry e_tmp;
	if (e_tmp.parse(p+n, storage::parse_type_get) < 0) {
		delete[] p;
		return -1;
	}
	delete[] p;

	if (e.key != e_tmp.key) {
		log_warning("cannot found corresponding key (key=%s)", e_tmp.key.c_str());
		return -1;
	}
	e.flag = e_tmp.flag;
	e.size = e_tmp.size;
	e.version = e_tmp.version;

	// data (+2 -> "\r\n")
	if (this->_connection->readsize(e.size + 2, &p) < 0) {
		return -1;
	}
	shared_byte data(new uint8_t[e.size]);
	memcpy(data.get(), p, e.size);
	delete[] p;
	e.data = data;
	log_debug("storing data [%d bytes]", e.size);
	this->_result = result_touched;

	return 0;
}

int op_gat::_send_text_result(result r, const char* message) {
	int return_value = 0;
	if (r == result_touched
			&& this->_entry.is_data_available()) {
		char* response = NULL;
		int response_len = 0;
		this->_entry.response(&response, response_len, storage::response_type_get);
		return_value = this->_connection->write(response, response_len);
		delete[] response;
	} else {
		return_value = op_touch::_send_text_result(r, message);
	}
	return return_value;
}

int op_gat::_send_binary_result(result r, const char* message) {
	int return_value = 0;
	if (r == result_touched
			&& this->_entry.is_data_available()) {
		binary_response_header header(this->_opcode);
		char* body;
		this->_entry.response(header, &body, false);
		return_value = this->_send_binary_response(header, body);
		delete[] body;
	} else {
		return_value = op_touch::_send_binary_result(r, message);
	}
	return return_value;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
