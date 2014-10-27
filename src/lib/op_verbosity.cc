/**
 *	op_verbosity.cc
 *
 *	implementation of gree::flare::op_verbosity
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_verbosity.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_verbosity
 */
op_verbosity::op_verbosity(shared_connection c):
		op(c, "verbosity"),
		_verbosity(0),
		_option(storage::option_none) {
}

/**
 *	dtor for op_verbosity
 */
op_verbosity::~op_verbosity() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_verbosity::run_client(int verbosity, storage::option option) {
	if (this->_run_client(verbosity, option) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters(option);
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_verbosity::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	try {
		// verbosity
		int n = util::next_digit(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no verbosity found", 0);
			throw -1;
		}
		try {
			this->_verbosity = boost::lexical_cast<int>(q);
			log_debug("storing verbosity [%d]", this->_verbosity);
		} catch (boost::bad_lexical_cast e) {
			log_debug("invalid verbosity (verbosity=%s)", q);
			throw -1;
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
int op_verbosity::_run_server() {
	// nothing to do

	if (this->_option & storage::option_noreply) {
		return 0;
	} else {
		return this->_send_result(result_ok);
	}
}

int op_verbosity::_run_client(int verbosity, storage::option option) {
	char request[BUFSIZ];
	int offset = snprintf(request, sizeof(request), "verbosity %d", verbosity);
	if (option & storage::option_noreply) {
		offset += snprintf(request+offset, sizeof(request)-offset, " %s", storage::option_cast(storage::option_noreply).c_str());
	}

	return this->_send_request(request);
}

int op_verbosity::_parse_text_client_parameters(storage::option option) {
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
