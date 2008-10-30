/**
 *	op_set.cc
 *
 *	implementation of gree::flare::op_set
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_set.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_set
 */
op_set::op_set(shared_connection c, cluster* cl, storage* st):
		op(c, "set"),
		_cluster(cl),
		_storage(st) {
}

/**
 *	dtor for op_set
 */
op_set::~op_set() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_set::run_client() {
	if (this->_run_client() < 0) {
		return -1;
	}

	return this->_parse_client_parameter();
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_set::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	try {
		// key
		int n = util::next_word(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no key found", 0);
			throw -1;
		}
		this->_entry.key = q;
		log_debug("storing key [%s]", this->_entry.key.c_str());

		// flag
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no flag found", 0);
			throw -1;
		}
		try {
			this->_entry.flag = lexical_cast<uint32_t>(q);
			log_debug("storing flag [%u]", this->_entry.flag);
		} catch (bad_lexical_cast e) {
			log_debug("invalid flag (flag=%s)", q);
			throw -1;
		}
		
		// expire
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no expire found", 0);
			throw -1;
		}
		try {
			this->_entry.expire = lexical_cast<time_t>(q);
			log_debug("storing expire [%u]", this->_entry.expire);
		} catch (bad_lexical_cast e) {
			log_debug("invalid expire (expire=%s)", q);
			throw -1;
		}

		// size
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no size found", 0);
			throw -1;
		}
		try {
			this->_entry.size = lexical_cast<uint64_t>(q);
			log_debug("storing size [%u]", this->_entry.size);
		} catch (bad_lexical_cast e) {
			log_debug("invalid size (size=%s)", q);
			throw -1;
		}

		// version (if we have)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_entry.version = lexical_cast<uint64_t>(q);
				log_debug("storing version [%u]", this->_entry.version);
			} catch (bad_lexical_cast e) {
				log_debug("invalid version (version=%s)", q);
				throw -1;
			}
		}

		// option
		n += util::next_word(p+n, q, sizeof(q));
		while (q[0]) {
			storage::option r;
			if (storage::option_cast(q, r) < 0) {
				log_debug("unknown option [%s] (cast failed)", q);
				throw -1;
			}
			this->_entry.option |= r;
			log_debug("storing option [%s -> %d]", q, r);

			n += util::next_word(p+n, q, sizeof(q));
		}
	} catch (int e) {
		_delete_(p);
		return e;
	}
	_delete_(p);

	// data (+2 -> "\r\n")
	if (this->_connection->readsize(this->_entry.size + 2, &p) < 0) {
		return -1;
	}
	shared_byte data(new uint8_t[this->_entry.size]);
	memcpy(data.get(), p, this->_entry.size);
	_delete_(p);
	this->_entry.data = data;
	log_debug("storing data [%d bytes]", this->_entry.size);

	return 0;
}

int op_set::_run_server() {
	// pre-proxy (proxy if node is not in request-partition)
	cluster::proxy_request r_proxy = this->_cluster->pre_proxy_write(this);
	if (r_proxy == cluster::proxy_request_complete) {
		return 0;
	} else if (r_proxy == cluster::proxy_request_error_partition) {
		return this->_send_error(error_type_server, "no partition available");
	}

	// storage i/o
	storage::result r_storage;
	if (this->_storage->set(this->_entry, r_storage) < 0) {
		return this->_send_error(error_type_server, "i/o error");
	}
	
	// post-proxy (notify updates to slaves if we need)
	
	string s = storage::result_cast(r_storage);
	return this->_connection->writeline(s.c_str());
}

int op_set::_run_client() {
	return 0;
}

int op_set::_parse_client_parameter() {
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
