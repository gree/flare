/**
 *	op_dump_key.cc
 *
 *	implementation of gree::flare::op_dump_key
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_dump_key.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_dump_key
 */
op_dump_key::op_dump_key(shared_connection c, cluster* cl, storage* st):
		op(c, "dump"),
		_cluster(cl),
		_storage(st),
		_partition(-1),
		_partition_size(0) {
}

/**
 *	dtor for op_dump_key
 */
op_dump_key::~op_dump_key() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_dump_key::run_client(int partition, int parition_size) {
	if (this->_run_client(partition, parition_size) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters();
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_dump_key::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	try {
		// partition (optional)
		int n = util::next_digit(p, q, sizeof(q));
		if (q[0]) {
			try {
				this->_partition = boost::lexical_cast<int>(q);
				log_debug("storing partition [%d]", this->_partition);
			} catch (boost::bad_lexical_cast e) {
				log_debug("invalid partition (partition=%s)", q);
				throw -1;
			}
		}

		// parition_size (optional)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_partition_size = boost::lexical_cast<int>(q);
				log_debug("storing parition_size [%d]", this->_partition_size);
			} catch (boost::bad_lexical_cast e) {
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
		delete[] p;
		return e;
	}
	delete[] p;

	return 0;
}

int op_dump_key::_run_server() {
	if (this->_storage->iter_begin() < 0) {
		return this->_send_result(result_server_error, "database busy");
	}

	key_resolver* kr = this->_cluster->get_key_resolver();

	storage::entry e;
	storage::iteration i;
	while ((i = this->_storage->iter_next(e.key)) == storage::iteration_continue) {
		if (this->_partition >= 0) {
			int key_hash_value = e.get_key_hash_value(this->_cluster->get_key_hash_algorithm());
			int p = kr->resolve(key_hash_value, this->_partition_size);
			if (p != this->_partition) {
				log_debug("skipping entry (key=%s, key_hash_value=%d, mod=%d, partition=%d, partition_size=%d)", e.key.c_str(), key_hash_value, p, this->_partition, this->_partition_size);
				continue;
			}
		}

		string s = "KEY ";
		int n = this->_connection->writeline((s + e.key).c_str());
		if (n < 0) {
			break;
		}
	}

	this->_storage->iter_end();

	if (i == storage::iteration_error) {
		return this->_send_result(result_server_error);
	}
	return this->_send_result(result_end);
}

int op_dump_key::_run_client(int partition, int partition_size) {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "dump_key %d %d", partition, partition_size);

	return this->_send_request(request);
}

int op_dump_key::_parse_text_client_parameters() {
	for (;;) {
		if (this->_thread_available && this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			break;
		}

		char* p;
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}

		if (this->_thread_available && this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			delete[] p;
			break;
		}

		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			break;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "KEY") != 0) {
			log_debug("invalid token (q=%s)", q);
			delete[] p;
			return -1;
		}

		n += util::next_word(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no key-entry found", 0);
			delete[] p;
			return -1;
		}

		delete[] p;
		// TODO: handle dumped key
	}

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
