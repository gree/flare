/**
 *	handler_dump_replication.cc
 *
 *	implementation of gree::flare::handler_dump_replication
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#include "handler_dump_replication.h"
#include "connection_tcp.h"
#include "op_set.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for handler_dump_replication
 */
handler_dump_replication::handler_dump_replication(shared_thread t, cluster* cl, storage* st, string server_name, int server_port, int partition, int partition_size, int wait, int bwlimit):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_replication_server_name(server_name),
		_replication_server_port(server_port),
		_partition(partition),
		_partition_size(partition_size),
		_wait(wait),
		_bwlimit(bwlimit) {
		this->_prior_tv.tv_sec = 0;
		this->_prior_tv.tv_usec = 0;
}

/**
 *	dtor for handler_dump_replication
 */
handler_dump_replication::~handler_dump_replication() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int handler_dump_replication::run() {
	this->_thread->set_peer(this->_replication_server_name, this->_replication_server_port);
	this->_thread->set_state("connect");

	shared_connection c(new connection_tcp(this->_replication_server_name, this->_replication_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to cluster replication server (name=%s, port=%d)", this->_replication_server_name.c_str(), this->_replication_server_port);
		this->_cluster->set_cluster_replication(false);
		return -1;
	}

	this->_thread->set_state("execute");
	this->_thread->set_op("dump");

	key_resolver* kr = this->_cluster->get_key_resolver();

	this->_prior_tv.tv_sec = 0;
	this->_prior_tv.tv_usec = 0;

	if (this->_storage->iter_begin() < 0) {
		log_debug("database busy", 0);
		return -1;
	}

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

		// replicate
		op_set* p = new op_set(this->_connection, this->_cluster, this->_storage);
		if (p->run_client(e) < 0) {
			delete p;
			break;
		}

		delete p;

		// wait
		long elapsed_usec = 0;
		if (this->_bwlimit > 0) {
			elapsed_usec = this->_sleep_for_bwlimit(e.key.size());
		}
		if (this->_wait > 0 && this->_wait-elapsed_usec > 0) {
			log_debug("wait for %d usec", this->_wait);
			usleep(this->_wait-elapsed_usec);
		}
	}

	this->_storage->iter_end();
	log_notice("dump replication completed (partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
		     this->_partition, this->_partition_size, this->_wait, this->_bwlimit);

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// code from rsync 2.6.9
long handler_dump_replication::_sleep_for_bwlimit(int bytes_written) {
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

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
