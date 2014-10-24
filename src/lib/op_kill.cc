/**
 *	op_kill.cc
 *
 *	implementation of gree::flare::op_kill
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_kill.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_kill
 */
op_kill::op_kill(shared_connection c, thread_pool* tp):
		op(c, "kill"),
		_thread_pool(tp),
		_id(0) {
}

/**
 *	dtor for op_kill
 */
op_kill::~op_kill() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int op_kill::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	try {
		int n = util::next_digit(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no thread id found", 0);
			throw -1;
		}

		try {
			this->_id = boost::lexical_cast<unsigned int>(q);
			log_debug("storing id [%u]", this->_id);
		} catch (boost::bad_lexical_cast e) {
			log_debug("invalid thread id (id=%s)", q);
			throw -1;
		}

		// no extra parameter allowed
		util::next_word(p+n, q, sizeof(q));
		if (q[0]) {
			log_debug("bogus string(s) found [%s] -> error", q);
			throw -1;
		}
	} catch (int e) {
		delete[] p;
		return e;
	}

	delete[] p;

	return 0;
}

int op_kill::_run_server() {
	log_info("killing thread (id=%u)", this->_id);

	shared_thread t;
	if (this->_thread_pool->get_active(this->_id, t) < 0) {
		log_debug("specified thread (id=%u) not found", this->_id);
		this->_send_result(result_client_error, "thread not found");
		return -1;
	}

	t->set_state("killed");
	t->shutdown(true, true);

	return this->_send_result(result_ok);
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
