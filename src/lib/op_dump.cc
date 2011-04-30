/**
 *	op_dump.cc
 *
 *	implementation of gree::flare::op_dump
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_dump.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_dump
 */
op_dump::op_dump(shared_connection c, cluster* cl, storage* st):
		op(c, "dump"),
		_cluster(cl),
		_storage(st),
		_wait(0),
		_partition(-1),
		_partition_size(0) {
}

/**
 *	dtor for op_dump
 */
op_dump::~op_dump() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_dump::run_client(int wait, int partition, int parition_size) {
	if (this->_run_client(wait, partition, parition_size) < 0) {
		return -1;
	}

	return this->_parse_client_parameter();
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_dump::_parse_server_parameter() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	try {
		// wait (optional)
		int n = util::next_digit(p, q, sizeof(q));
		if (q[0]) {
			try {
				this->_wait = lexical_cast<int>(q);
				log_debug("storing wait [%d]", this->_wait);
			} catch (bad_lexical_cast e) {
				log_debug("invalid wait (wait=%s)", q);
				throw -1;
			}
			if (this->_wait < 0) {
				log_debug("invalid wait (wait=%d)", this->_wait);
				throw -1;
			}
		}

		// partition (optional)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_partition = lexical_cast<int>(q);
				log_debug("storing partition [%d]", this->_partition);
			} catch (bad_lexical_cast e) {
				log_debug("invalid partition (partition=%s)", q);
				throw -1;
			}
		}

		// parition_size (optional)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_partition_size = lexical_cast<int>(q);
				log_debug("storing parition_size [%d]", this->_partition_size);
			} catch (bad_lexical_cast e) {
				log_debug("invalid partition_size (partition_size=%s)", q);
				throw -1;
			}
			if (this->_partition_size < 0) {
				log_debug("invalid partition_size (partition_size=%d)", this->_partition_size);
				throw -1;
			}
		}

		if (this->_partition >= 0) {
			if (this->_partition_size <= 0 || this->_partition_size < this->_partition+1) {
				log_debug("invalid partition_size (partition=%d, partition_size=%d)", this->_partition, this->_partition_size);
				throw -1;
			}
		}
		if (this->_partition_size > 0) {
			if (this->_partition < 0) {
				log_debug("invalid partition (partition=%d, partition_size=%d)", this->_partition, this->_partition_size);
				throw -1;
			}
		}
	} catch (int e) {
		_delete_(p);
		return e;
	}
	_delete_(p);

	return 0;
}

int op_dump::_run_server() {
	if (this->_storage->iter_begin() < 0) {
		return this->_send_result(result_server_error, "database busy");
	}

	key_resolver* kr = this->_cluster->get_key_resolver();

	storage::entry e;
	while (this->_storage->iter_next(e.key) >= 0) {
		if (this->_partition >= 0) {
			int key_hash_value = e.get_key_hash_value();
			int p = kr->resolve(key_hash_value, this->_partition_size);
			if (p != this->_partition) {
				log_debug("skipping entry (key=%s, key_hash_value=%d, mod=%d, partition=%d, partition_size=%d)", e.key.c_str(), key_hash_value, p, this->_partition, this->_partition_size);
				continue;
			}
		}

		storage::result r;
		if (this->_storage->get(e, r) < 0) {
			log_err("skipping entry [get() error] (key=%s)", e.key.c_str());
			continue;
		} else if (r == storage::result_not_found) {
			log_info("skipping entry [key not found (perhaps expired)] (key=%s)", e.key.c_str());
			continue;
		}

		char *response;
		int response_len;
		e.response(&response, response_len, storage::response_type_dump);
		int n = this->_connection->write(response, response_len);
		_delete_(response);
		if (n < 0) {
			break;
		}

		// wait
		if (this->_wait > 0) {
			log_debug("wait for %d usec", this->_wait);
			usleep(this->_wait);
		}
	}

	this->_storage->iter_end();

	return this->_send_result(result_end);
}

int op_dump::_run_client(int wait, int partition, int partition_size) {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "dump %d %d %d", wait, partition, partition_size);

	return this->_send_request(request);
}

int op_dump::_parse_client_parameter() {
	int items = 0;
	for (;;) {
		if (this->_thread_available && this->_thread->is_shutdown_request()) {
			log_notice("thread shutdown request -> breaking loop", 0);
			break;
		}

		char* p;
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}

		if (this->_thread_available && this->_thread->is_shutdown_request()) {
			log_notice("thread shutdown request -> breaking loop", 0);
			_delete_(p);
			break;
		}

		if (strcmp(p, "END\n") == 0) {
			_delete_(p);
			log_notice("found delimiter, dump completed (items=%d)", items);
			break;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "VALUE") != 0) {
			log_debug("invalid token (q=%s)", q);
			_delete_(p);
			return -1;
		}

		storage::entry e;
		if (e.parse(p+n, storage::parse_type_get) < 0) {
			_delete_(p);
			return -1;
		}
		_delete_(p);

		// data (+2 -> "\r\n")
		if (this->_connection->readsize(e.size + 2, &p) < 0) {
			return -1;
		}
		shared_byte data(new uint8_t[e.size]);
		memcpy(data.get(), p, e.size);
		_delete_(p);
		e.data = data;
		log_debug("storing data [%d bytes]", e.size);

		storage::result r;
		if (this->_storage->set(e, r, storage::behavior_dump) < 0) {
			log_warning("something is going wrong while storing data -> continue processing", 0);
			// nop
		}
		items++;
	}

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
