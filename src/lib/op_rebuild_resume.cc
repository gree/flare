/**
 *	op_rebuild_resume.cc
 *
 *	implementation of gree::flare::op_rebuild_resume (see the header)
 */
#include "op_rebuild_resume.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

op_rebuild_resume::op_rebuild_resume(shared_connection c, cluster* cl, storage* st):
		op(c, "rebuild_resume"),
		_cluster(cl),
		_storage(st),
		_discard(false) {
}

op_rebuild_resume::~op_rebuild_resume() {
}

int op_rebuild_resume::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (n > 0 && strcmp(q, "discard") == 0) {
		this->_discard = true;
		n += util::next_word(p+n, q, sizeof(q));
		this->_grant.pod_uid = q;
		n += util::next_word(p+n, q, sizeof(q));
		this->_grant.copy_id = q;
		n += util::next_word(p+n, q, sizeof(q));
		this->_grant.map_version = strtoull(q, NULL, 10);
	}
	delete[] p;
	return 0;
}

discard_grant_facts op_rebuild_resume::gather_facts(cluster* cl, storage* st) {
	discard_grant_facts f;
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = st ? dynamic_cast<storage_rocksdb*>(st) : NULL;
	const char* uid = getenv("FLARE_POD_UID");
	f.own_pod_uid = uid != NULL ? uid : "";
	if (rdb != NULL) {
		f.own_copy_id = rdb->get_copy_id();
		f.identity_consistent = rdb->copy_identity_consistent();
		f.quarantined = rdb->is_quarantined();
		f.switch_unresolved = rdb->is_switch_unresolved();
		f.parked_no_space = rdb->is_rebuild_parked() && rdb->get_rebuild_blocked() == "no_space";
	}
	if (cl != NULL) {
		cluster::role r = cluster::role_proxy;
		cluster::state s = cluster::state_active;
		int partition = -1;
		f.role_known = cl->get_own_assignment(r, s, partition);
		f.serving_or_master = !f.role_known || r == cluster::role_master || (r == cluster::role_slave && s == cluster::state_active);
		f.own_map_version = cl->get_node_map_version();
	}
#else
	(void)cl;
	(void)st;
#endif
	return f;
}

int op_rebuild_resume::_run_server() {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = this->_storage ? dynamic_cast<storage_rocksdb*>(this->_storage) : NULL;
	if (rdb == NULL) {
		return this->_send_result(result_server_error, "not_supported");
	}
	char line[BUFSIZ];
	if (this->_discard) {
		// every binding is checked now; refused = nothing changes (stays parked)
		const string why = check_discard_grant(this->_grant, gather_facts(this->_cluster, this->_storage), true);
		if (!why.empty()) {
			log_warning("rebuild_resume discard REFUSED (%s): the rebuild stays parked and the copy is kept", why.c_str());
			snprintf(line, sizeof(line), "STAT rebuild_resumed 0\r\nSTAT rebuild_discard_grant refused:%s\r\n", why.c_str());
			this->_connection->write(line, strlen(line));
			return this->_send_result(result_end);
		}
		rdb->set_discard_grant(this->_grant);
		snprintf(line, sizeof(line), "STAT rebuild_resumed 1\r\nSTAT rebuild_discard_grant accepted\r\n");
		this->_connection->write(line, strlen(line));
		return this->_send_result(result_end);
	}
	const bool was = rdb->resume_rebuild();
	snprintf(line, sizeof(line), "STAT rebuild_resumed %d\r\n", was ? 1 : 0);
	this->_connection->write(line, strlen(line));
	return this->_send_result(result_end);
#else
	(void)this->_storage;
	(void)this->_cluster;
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

}	// namespace flare
}	// namespace gree
