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
	pthread_mutex_init(&this->_busy_mutex, NULL);
}

handler_authority::~handler_authority() {
	// a round still running holds `this`: wait (bounded) for it
	for (int i = 0; i < 500; i++) {
		pthread_mutex_lock(&this->_busy_mutex);
		const bool idle = this->_busy.empty();
		pthread_mutex_unlock(&this->_busy_mutex);
		if (idle) {
			break;
		}
		usleep(10000);
	}
	pthread_mutex_destroy(&this->_busy_mutex);
}

std::vector<write_promise::members> handler_authority::_due() {
	std::vector<write_promise::members> due;
	const std::vector<uint32_t> parts = write_promise::member_partitions();
	for (size_t i = 0; i < parts.size(); i++) {
		write_promise::members m;
		if (!write_promise::get_members(parts[i], m) || m.solo) {
			continue;
		}
		const uint64_t now = write_fence::authority_now_ns();
		std::map<uint32_t, uint64_t>::const_iterator last = this->_last_round_ns.find(parts[i]);
		// a new membership (term / generation) has no grant yet (the old one was ended when it was
		// accepted): its first round does not wait for the renew interval
		const std::pair<uint64_t, uint64_t> scope(m.term, m.generation);
		std::map<uint32_t, std::pair<uint64_t, uint64_t> >::const_iterator ls = this->_last_scope.find(parts[i]);
		const bool new_scope = ls == this->_last_scope.end() || ls->second != scope;
		if (now == write_fence::authority_clock_failed
				|| (!new_scope && last != this->_last_round_ns.end() && now >= last->second && now - last->second < m.renew_ms * 1000000ULL)) {
			continue;
		}
		pthread_mutex_lock(&this->_busy_mutex);
		const bool busy = this->_busy.count(parts[i]) != 0;
		if (!busy) {
			this->_busy.insert(parts[i]);
		}
		pthread_mutex_unlock(&this->_busy_mutex);
		if (busy) {
			continue;
		}
		this->_last_round_ns[parts[i]] = now;
		this->_last_scope[parts[i]] = scope;
		due.push_back(m);
	}
	return due;
}

void handler_authority::round(const write_promise::members& m, uint64_t nonce) {
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
	pthread_mutex_lock(&this->_busy_mutex);
	this->_busy.erase(m.partition);
	pthread_mutex_unlock(&this->_busy_mutex);
}

void* handler_authority::_round_thread(void* arg) {
	round_arg* a = static_cast<round_arg*>(arg);
	a->self->round(a->m, a->nonce);
	delete a;
	return NULL;
}

size_t handler_authority::dispatch() {
	size_t started = 0;
	const std::vector<write_promise::members> due = this->_due();
	for (size_t i = 0; i < due.size(); i++) {
		// the send point is taken HERE, before the thread (and any request) exists
		const uint64_t nonce = write_promise::begin_round(due[i]);
		if (nonce == 0) {
			pthread_mutex_lock(&this->_busy_mutex);
			this->_busy.erase(due[i].partition);
			pthread_mutex_unlock(&this->_busy_mutex);
			continue;
		}
		round_arg* a = new round_arg();
		a->self = this;
		a->m = due[i];
		a->nonce = nonce;
		pthread_t th;
		pthread_attr_t attr;
		pthread_attr_init(&attr);
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
		if (pthread_create(&th, &attr, &handler_authority::_round_thread, a) != 0) {
			log_err("write authority: could not start a round thread for partition %u", due[i].partition);
			delete a;
			pthread_mutex_lock(&this->_busy_mutex);
			this->_busy.erase(due[i].partition);
			pthread_mutex_unlock(&this->_busy_mutex);
		} else {
			started++;
		}
		pthread_attr_destroy(&attr);
	}
	return started;
}

int handler_authority::run() {
	this->_thread->set_state("authority");
	this->_thread->set_op("");
	while (!this->_thread->is_shutdown_request()) {
		this->dispatch();
		usleep(20000);
	}
	this->_thread->set_state("shutdown");
	return 0;
}

bool handler_authority::run_once() {
	bool ran = false;
	const std::vector<write_promise::members> due = this->_due();
	for (size_t i = 0; i < due.size(); i++) {
		const uint64_t nonce = write_promise::begin_round(due[i]);
		if (nonce == 0) {
			pthread_mutex_lock(&this->_busy_mutex);
			this->_busy.erase(due[i].partition);
			pthread_mutex_unlock(&this->_busy_mutex);
			continue;
		}
		ran = true;
		this->round(due[i], nonce);
	}
	return ran;
}

}	// namespace flare
}	// namespace gree
