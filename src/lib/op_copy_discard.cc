/**
 *	op_copy_discard.cc
 *
 *	implementation of gree::flare::op_copy_discard (see the header)
 */
#include "op_copy_discard.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

op_copy_discard::op_copy_discard(shared_connection c, cluster* cl, storage* st):
		op(c, "copy_discard"),
		_cluster(cl),
		_storage(st) {
}

op_copy_discard::~op_copy_discard() {
}

int op_copy_discard::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	this->_request_id = q;
	n += util::next_word(p+n, q, sizeof(q));
	this->_operation = q;
	n += util::next_word(p+n, q, sizeof(q));
	this->_copy_id = q;
	delete[] p;
	if (this->_request_id.empty() || this->_operation.empty() || this->_copy_id.empty()) {
		log_warning("copy_discard: usage copy_discard <request-id> <operation> <copy-id>", 0);
		return -1;
	}
	return 0;
}

int op_copy_discard::_run_server() {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = this->_storage ? dynamic_cast<storage_rocksdb*>(this->_storage) : NULL;
	if (rdb == NULL) {
		return this->_send_result(result_server_error, "not_supported");
	}
	// the live copy is discarded only on a node that is neither a master nor
	// serving (Active): the case is a replica whose rebuild stopped for room
	bool may_discard_live = false;
	if (this->_cluster != NULL) {
		cluster::role r = cluster::role_proxy;
		cluster::state st = cluster::state_active;
		int partition = -1;
		may_discard_live = this->_cluster->get_own_assignment(r, st, partition)
			&& r != cluster::role_master && !(r == cluster::role_slave && st == cluster::state_active);
	}
	string result;
	rdb->discard_copy(this->_request_id, this->_operation, this->_copy_id, may_discard_live, result);
	char line[BUFSIZ];
	snprintf(line, sizeof(line), "STAT copy_discard_result %s\r\n", result.c_str());
	this->_connection->write(line, strlen(line));
	return this->_send_result(result_end);
#else
	(void)this->_cluster;
	(void)this->_storage;
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

}	// namespace flare
}	// namespace gree
