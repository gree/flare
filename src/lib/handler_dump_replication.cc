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
handler_dump_replication::handler_dump_replication(shared_thread t, cluster* cl, storage* st, string server_name, int server_port):
		thread_handler(t),
		_cluster(cl),
		_storage(st),
		_replication_server_name(server_name),
		_replication_server_port(server_port),
		_total_written(0) {
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

	shared_connection c(new connection_tcp(
			   this->_replication_server_name, this->_replication_server_port));
	this->_connection = c;
	if (c->open() < 0) {
		log_err("failed to connect to cluster replication server (name=%s, port=%d)",
				   this->_replication_server_name.c_str(), this->_replication_server_port);
		return -1;
	}

	this->_thread->set_state("execute");
	this->_thread->set_op("dump");

	this->_prior_tv.tv_sec = 0;
	this->_prior_tv.tv_usec = 0;

	if (this->_storage->iter_begin() < 0) {
		log_err("database busy", 0);
		return -1;
	}

	key_resolver* kr = this->_cluster->get_key_resolver();
	cluster::node n = this->_cluster->get_node(this->_cluster->get_server_name(), this->_cluster->get_server_port());
	int partition = n.node_partition;
	int partition_size = this->_cluster->get_node_partition_map_size();
	int wait = this->_cluster->get_reconstruction_interval();
	int bwlimit = this->_cluster->get_reconstruction_bwlimit();

	log_notice("starting dump replication (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
			   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, bwlimit);
	storage::entry e;
	storage::iteration i;
	while ((i = this->_storage->iter_next(e.key)) == storage::iteration_continue
			&& this->_thread && !this->_thread->is_shutdown_request()) {
		if (partition >= 0) {
			partition_size = this->_cluster->get_node_partition_map_size();
			int key_hash_value = e.get_key_hash_value(this->_cluster->get_key_hash_algorithm());
			int p = kr->resolve(key_hash_value, partition_size);
			if (p != partition) {
				log_debug("skipping entry (key=%s, key_hash_value=%d, mod=%d, partition=%d, partition_size=%d)",
						   e.key.c_str(), key_hash_value, p, partition, partition_size);
				continue;
			}
		}

		storage::result r;
		if (this->_storage->get(e, r) < 0) {
			if (r == storage::result_not_found) {
				log_info("skipping entry [key not found (perhaps expired)] (key=%s)", e.key.c_str());
			} else {
				log_err("skipping entry [get() error] (key=%s)", e.key.c_str());
			}
			continue;
		}

		// replicate
		op_set* p = new op_set(this->_connection, NULL, NULL);
		if (p->run_client(e) < 0) {
			delete p;
			break;
		}

		delete p;

		// wait
		long elapsed_usec = 0;
		if (bwlimit > 0) {
			elapsed_usec = this->_sleep_for_bwlimit(e.size, bwlimit);
		}
		if (wait > 0 && wait-elapsed_usec > 0) {
			log_debug("wait for %d usec", wait);
			usleep(wait-elapsed_usec);
		}
	}

	this->_storage->iter_end();
	if (!this->_thread->is_shutdown_request()) {
		log_notice("dump replication completed (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, bwlimit);
	} else {
		this->_thread->set_state("shutdown");
		log_warning("dump replication interruptted (dest=%s:%d, partition=%d, partition_size=%d, interval=%d, bwlimit=%d)",
				   this->_replication_server_name.c_str(), this->_replication_server_port, partition, partition_size, wait, bwlimit);
	}
	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// code from rsync 2.6.9
long handler_dump_replication::_sleep_for_bwlimit(int bytes_written, int bwlimit) {
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
		this->_total_written -= elapsed_usec * bwlimit / (one_sec/1024);
		if (this->_total_written < 0) {
			this->_total_written = 0;
		}
	}

	long sleep_usec = this->_total_written * (one_sec/1024) / bwlimit;
	if (sleep_usec < one_sec / 10) {
		this->_prior_tv = start_tv;
		return 0;
	}

	usleep(sleep_usec);

	gettimeofday(&this->_prior_tv, NULL);
	elapsed_usec = (this->_prior_tv.tv_sec - start_tv.tv_sec) * one_sec
		     + (this->_prior_tv.tv_usec - start_tv.tv_usec);
	this->_total_written = (sleep_usec - elapsed_usec) * bwlimit / (one_sec/1024);

	return elapsed_usec;
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
