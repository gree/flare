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
#include "connection_tcp.h"

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
		_partition_size(0),
		_bwlimit(0),
		_total_written(0) {
	this->_prior_tv.tv_sec = 0;
	this->_prior_tv.tv_usec = 0;
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
int op_dump::run_client(int wait, int partition, int parition_size, int bwlimit) {
	if (this->_run_client(wait, partition, parition_size, bwlimit) < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters();
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_dump::_parse_text_server_parameters() {
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
				this->_wait = boost::lexical_cast<int>(q);
				log_debug("storing wait [%d]", this->_wait);
			} catch (boost::bad_lexical_cast e) {
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

		// bwlimit (optional)
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0]) {
			try {
				this->_bwlimit = boost::lexical_cast<int>(q);
				log_debug("storing bwlimit [%d]", this->_bwlimit);
			} catch (boost::bad_lexical_cast e) {
				log_debug("invalid bwlimit (bwlimit=%s)", q);
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

int op_dump::_run_server() {
	this->_prior_tv.tv_sec = 0;
	this->_prior_tv.tv_usec = 0;

	if (!this->_thread) {
		return this->_send_result(result_server_error, "thread not set");
	}

	if (this->_storage->iter_begin() < 0) {
		return this->_send_result(result_server_error, "database busy");
	}

	bool nodelay_saved = false;
	if (connection_tcp* ctp = dynamic_cast<connection_tcp*>(this->_connection.get())) {
		ctp->get_tcp_nodelay(nodelay_saved);
		ctp->set_tcp_nodelay(false);
	}

	key_resolver* kr = this->_cluster->get_key_resolver();

	storage::entry e;
	storage::iteration i;
	while ((i = this->_storage->iter_next(e.key)) == storage::iteration_continue
			&& this->_thread && !this->_thread->is_shutdown_request()) {
		if (this->_partition >= 0) {
			int key_hash_value = e.get_key_hash_value(this->_cluster->get_key_hash_algorithm());
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
		delete[] response;
		if (n < 0) {
			break;
		}

		// wait
		long elapsed_usec = 0;
		if (this->_bwlimit > 0) {
			elapsed_usec = this->_sleep_for_bwlimit(n);
		}
		if (this->_wait > 0 && this->_wait-elapsed_usec > 0) {
			log_debug("wait for %d usec", this->_wait);
			usleep(this->_wait-elapsed_usec);
		}
	}

	this->_storage->iter_end();

	if (connection_tcp* ctp = dynamic_cast<connection_tcp*>(this->_connection.get())) {
		ctp->set_tcp_nodelay(nodelay_saved);
	}

	if (!this->_thread) {
		return this->_send_result(result_server_error, "thread not set");
	} else if (this->_thread->is_shutdown_request()) {
		return this->_send_result(result_server_error, "operation interrupted");
	} else if (i != storage::iteration_end) {
		return this->_send_result(result_server_error, "iteration canceled");
	} else {
		return this->_send_result(result_end);
	}
}

int op_dump::_run_client(int wait, int partition, int partition_size, int bwlimit) {
	char request[BUFSIZ];
	if (bwlimit > 0) {
		snprintf(request, sizeof(request), "dump %d %d %d %d", wait, partition, partition_size, bwlimit);
	} else {
		snprintf(request, sizeof(request), "dump %d %d %d", wait, partition, partition_size);	// Backward compatibility.
	}
	return this->_send_request(request);
}

int op_dump::_parse_text_client_parameters() {
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
			delete[] p;
			break;
		}

		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			log_notice("found delimiter, dump completed (items=%d)", items);
			break;
		} else if (strcmp(p, "SERVER_ERROR\n") == 0) {
			delete[] p;
			log_err("something is going wrong, dump uncomplete (items=%d)", items);
			return -1;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "VALUE") != 0) {
			log_debug("invalid token (q=%s)", q);
			delete[] p;
			return -1;
		}

		storage::entry e;
		if (e.parse(p+n, storage::parse_type_get) < 0) {
			delete[] p;
			return -1;
		}
		delete[] p;

		// data (+2 -> "\r\n")
		if (this->_connection->readsize(e.size + 2, &p) < 0) {
			return -1;
		}
		shared_byte data(new uint8_t[e.size]);
		memcpy(data.get(), p, e.size);
		delete[] p;
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

// code from rsync 2.6.9
long op_dump::_sleep_for_bwlimit(int bytes_written) {
	if (bytes_written == 0) {
		return 0;
	}

	this->_total_written += bytes_written;

	static const long one_sec = 1000000L; // of microseconds in a second.

	long elapsed_usec;
	struct timeval start_tv;
	gettimeofday(&start_tv, NULL);
	if (this->_prior_tv.tv_sec) {
		elapsed_usec = (start_tv.tv_sec - this->_prior_tv.tv_sec) * one_sec
			+ (start_tv.tv_usec - this->_prior_tv.tv_usec);
		this->_total_written -= elapsed_usec * this->_bwlimit / (one_sec/1024);
		if (this->_total_written < 0) {
			this->_total_written = 0;
		}
	}

	long sleep_usec = this->_total_written * (one_sec/1024) / this->_bwlimit;
	if (sleep_usec < one_sec / 10) {
		this->_prior_tv = start_tv;
		return 0;
	}

	usleep(sleep_usec);

	gettimeofday(&this->_prior_tv, NULL);
	elapsed_usec = (this->_prior_tv.tv_sec - start_tv.tv_sec) * one_sec
		     + (this->_prior_tv.tv_usec - start_tv.tv_usec);
	this->_total_written = (sleep_usec - elapsed_usec) * this->_bwlimit / (one_sec/1024);

	return elapsed_usec;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
