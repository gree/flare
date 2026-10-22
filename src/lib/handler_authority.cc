/**
 *	handler_authority.cc
 *
 *	see handler_authority.h
 */
#include "handler_authority.h"
#include "op_authority.h"
#include "write_fence.h"

#include <unistd.h>

namespace gree {
namespace flare {

handler_authority::handler_authority(shared_thread t, cluster* cl):
		thread_handler(t),
		_cluster(cl) {
}

handler_authority::~handler_authority() {
}

int handler_authority::run() {
	this->_thread->set_state("authority");
	this->_thread->set_op("");
	while (!this->_thread->is_shutdown_request()) {
		this->run_once();
		usleep(20000);
	}
	this->_thread->set_state("shutdown");
	return 0;
}

bool handler_authority::run_once() {
	bool ran = false;
	const std::vector<uint32_t> parts = write_promise::member_partitions();
	for (size_t i = 0; i < parts.size(); i++) {
		write_promise::members m;
		if (!write_promise::get_members(parts[i], m) || m.solo) {
			continue;
		}
		const uint64_t now = write_fence::authority_now_ns();
		std::map<uint32_t, uint64_t>::const_iterator last = this->_last_round_ns.find(parts[i]);
		if (now == write_fence::authority_clock_failed
				|| (last != this->_last_round_ns.end() && now >= last->second && now - last->second < m.renew_ms * 1000000ULL)) {
			continue;
		}
		this->_last_round_ns[parts[i]] = now;
		const uint64_t nonce = write_promise::begin_round(m);
		if (nonce == 0) {
			continue;
		}
		ran = true;
		const int timeout_ms = static_cast<int>(m.ttl_ms / 4 > 0 ? m.ttl_ms / 4 : 1);
		size_t promised = 0;
		for (size_t k = 0; k < m.successors.size(); k++) {
			string host;
			int port = 0;
			string why;
			if (this->_cluster->from_node_key(m.successors[k], host, port) < 0 || host.empty()
					|| !op_authority::request_promise(host, port, m.partition, m.term, m.generation, m.ttl_ms, nonce, timeout_ms, why)) {
				log_debug("write authority: no promise from %s (%s)", m.successors[k].c_str(), why.c_str());
				break;		// one missing promise: no grant; the next round tries again
			}
			promised++;
		}
		string why;
		if (!write_promise::finish_round(m, nonce, promised, why)) {
			log_debug("write authority: round for partition %u gave no grant: %s", m.partition, why.c_str());
		}
	}
	return ran;
}

}	// namespace flare
}	// namespace gree
