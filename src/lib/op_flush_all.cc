/**
 *	op_flush_all.cc
 *
 *	implementation of gree::flare::op_flush_all
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_flush_all.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_flush_all
 */
op_flush_all::op_flush_all(shared_connection c, storage* st):
		op(c, "flush_all", binary_header::opcode_flush),
		_storage(st),
		_expire(0),
		_option(storage::option_none) {
}

/**
 *	ctor for op_flush_all
 */
op_flush_all::op_flush_all(shared_connection c, string ident, binary_header::opcode opcode, storage* st):
		op(c, ident, opcode),
		_storage(st),
		_expire(0),
		_option(storage::option_none) {
}

/**
 *	dtor for op_flush_all
 */
op_flush_all::~op_flush_all() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_flush_all::run_client(time_t expire, storage::option option) {
	if (this->_run_client(expire, option) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters(option);
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_flush_all::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	try {
		// expire (optional)
		int n = util::next_digit(p, q, sizeof(q));
		if (q[0]) {
			try {
				this->_expire = boost::lexical_cast<time_t>(q);
				log_debug("storing expire [%ld]", this->_expire);
			} catch (boost::bad_lexical_cast e) {
				log_debug("invalid expire (expire=%s)", q);
				throw -1;
			}
		}

		// option
		n += util::next_word(p+n, q, sizeof(q));
		while (q[0]) {
			storage::option r = storage::option_none;
			if (storage::option_cast(q, r) < 0) {
				log_debug("unknown option [%s] (cast failed)", q);
				throw -1;
			}
			this->_option |= r;
			log_debug("storing option [%s -> %d]", q, r);

			n += util::next_word(p+n, q, sizeof(q));
		}
		if (this->_option & storage::option_sync) {
			log_debug("sync option is not supported in this op", 0);
			throw -1;
		}
	} catch (int e) {
		delete[] p;
		return e;
	}
	delete[] p;

	return 0;
}

/**
 *	process server request  
 *
 *	@todo support expire parameter
 */
int op_flush_all::_run_server() {
	if (this->_storage->truncate() < 0) {
		if (this->_option & storage::option_noreply) {
			return 0;
		} else {
			return this->_send_result(result_server_error, "unknown error");
		}
	}

	if (this->_option & storage::option_noreply) {
		return 0;
	} else {
		return this->_send_result(result_ok);
	}
}

int op_flush_all::_run_client(time_t expire, storage::option option) {
	char request[BUFSIZ];
	int offset = snprintf(request, sizeof(request), "flush_all %ld", expire);
	if (option & storage::option_noreply) {
		offset += snprintf(request+offset, sizeof(request)-offset, " %s", storage::option_cast(storage::option_noreply).c_str());
	}

	return this->_send_request(request);
}

int op_flush_all::_parse_text_client_parameters(storage::option option) {
	if (option & storage::option_noreply) {
		this->_result = result_none;
		return 0;
	}

	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	if (this->_parse_text_response(p, this->_result, this->_result_message) < 0) {
		delete[] p;
		return -1;
	}
	delete[] p;

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
