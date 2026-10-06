/**
 *	handler_source_validator.cc
 *
 *	R3: see handler_source_validator.h.
 */
#include "handler_source_validator.h"
#include "connection_tcp.h"
#include "op_meta.h"

namespace gree {
namespace flare {

handler_source_validator::handler_source_validator(shared_thread t, cluster* cl):
		thread_handler(t),
		_cluster(cl) {
}

handler_source_validator::~handler_source_validator() {
}

int handler_source_validator::run() {
	this->_thread->set_state("source_check");
	while (!this->_thread->is_shutdown_request()) {
		this->_cluster->wait_source_check(this->_cluster->get_source_check_interval_ms());
		if (this->_thread->is_shutdown_request()) {
			break;
		}
		this->_check_once();
	}
	return 0;
}

void handler_source_validator::probe(const string& node_key, cluster* cl, source_probe& p) {
	p = source_probe();
	string host;
	int port = 0;
	if (cl->from_node_key(node_key, host, port) < 0 || host.empty()) {
		return;
	}
	connection_tcp* t = new connection_tcp(host, port);
	t->set_connect_timeout_ms(3000);
	t->set_connect_retry_limit(1);
	t->set_read_timeout(5000);
	shared_connection c(t);
	if (c->open() < 0) {
		return;
	}
	t->set_deadline_from_now(8000);
	op_meta* meta = new op_meta(c, NULL, NULL);
	bool wal = false;
	string id;
	uint64_t lsn = 0;
	const int rc = meta->run_client_features(wal, id, lsn);
	p.source_epoch = meta->get_peer_source_epoch();
	p.epoch_token = meta->get_peer_epoch_token();
	delete meta;
	if (rc != 0 || id.empty()) {
		return;
	}
	p.master_id = id;
	p.complete = true;
}

void handler_source_validator::_check_once() {
	cluster::role r;
	cluster::state st;
	int partition = -1;
	if (!this->_cluster->get_own_assignment(r, st, partition) || r != cluster::role_slave || partition < 0) {
		return;
	}
	const source_binding b = this->_cluster->get_read_source();
	if (b.st == source_binding::none || b.st == source_binding::needs_rebuild) {
		return;
	}
	const string current = this->_cluster->get_partition_master_key(partition);
	source_probe p;
	if (!current.empty() && !b.master_id.empty()) {
		handler_source_validator::probe(current, this->_cluster, p);
	}
	const source_decision d = decide_source(b, current, p);
	if (d == decision_keep) {
		return;
	}
	ostringstream why;
	switch (d) {
	case decision_rebind:
		why << "partition master " << current << " has the copy's lineage " << b.master_id << " and history "
			<< (b.source_epoch.empty() ? string("(legacy: lineage only)") : b.source_epoch);
		break;
	case decision_wait_unknown:
		if (current.empty()) why << "the partition has no master in the accepted map";
		else if (!p.complete) why << "the partition master " << current << " could not be probed (Unknown)";
		else why << "the partition master " << current << " answered without a comparable source epoch (copy: "
			<< (b.source_epoch.empty() ? string("legacy") : b.source_epoch) << ")";
		break;
	case decision_needs_rebuild:
		if (p.master_id != b.master_id) why << "lineage differs: copy " << b.master_id << ", master " << current << " " << p.master_id;
		else why << "history differs: copy " << b.source_epoch << ", master " << current << " " << p.source_epoch;
		break;
	default:
		break;
	}
	this->_cluster->apply_source_decision(b.generation, current, d, why.str());
}

}	// namespace flare
}	// namespace gree
