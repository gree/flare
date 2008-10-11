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
		_thread_pool(tp) {
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
int op_kill::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	int n = util::next_digit(p, q, sizeof(q));
	if (q[0] == '\0') {
		log_debug("no digit found", 0);
		_delete_(p);
		return -1;
	}

	pthread_t id;
	try {
		id = lexical_cast<pthread_t>(q);
	} catch (bad_lexical_cast e) {
		log_debug("invalid digit found", 0);
		_delete_(p);
		return -1;
	}
	log_debug("storing thread id=%u", id);
	this->_id = id;

	// no extra parameter allowed
	util::next_word(p+n, q, sizeof(q));
	if (q[0]) {
		log_debug("bogus string(s) found [%s] -> error", q);
		_delete_(p);
		return -1;
	}

	_delete_(p);

	return 0;
}

int op_kill::_run_server() {
	log_info("killing thread (id=%u)", this->_id);

	shared_thread t;
	if (this->_thread_pool->get_active(this->_id, t) < 0) {
		log_debug("specified thread (id=%u) not found", this->_id);
		this->_send_error(error_type_client, "thread not found");
		return -1;
	}

	t->shutdown(true, true);
	t->set_state("killed");

	this->_send_ok();
	
	return 0;
}
// }}}

// {{{ private methods
// }}}

// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
