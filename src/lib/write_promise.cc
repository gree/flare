/**
 *	write_promise.cc
 *
 *	implementation of gree::flare::write_promise (see the header)
 */
#include "write_promise.h"
#include "write_fence.h"

#include <stdio.h>
#include <unistd.h>

namespace gree {
namespace flare {

namespace {
class guard {
public:
	explicit guard(pthread_mutex_t* m): _m(m) { pthread_mutex_lock(_m); }
	~guard() { pthread_mutex_unlock(_m); }
private:
	pthread_mutex_t* _m;
};
const uint64_t ms_ns = 1000000ULL;
const uint64_t max_ms = 1000ULL * 1000 * 60 * 60 * 24;		// a day: no overflow in ns
bool slave_always(int) { return true; }
}

pthread_mutex_t write_promise::_m = PTHREAD_MUTEX_INITIALIZER;
bool write_promise::_enabled = false;
uint64_t write_promise::_margin_ns = 0;
uint64_t write_promise::_max_ttl_ns = 0;
uint64_t write_promise::_boot_ns = 0;
bool (*write_promise::_is_slave)(int) = slave_always;
std::map<uint32_t, write_promise::rstate> write_promise::_r;
std::map<uint32_t, write_promise::members> write_promise::_members;

bool write_promise::configure(bool enabled, uint64_t margin_ms, uint64_t max_ttl_ms, std::string& why) {
	if (enabled && (margin_ms == 0 || max_ttl_ms == 0 || margin_ms > max_ms || max_ttl_ms > max_ms)) {
		why = "write-authority-enabled needs explicit write-authority-margin-ms and write-authority-max-ttl-ms (> 0)";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	if (enabled && now == write_fence::authority_clock_failed) {
		why = "the authority clock cannot be read";
		return false;
	}
	{
		guard g(&_m);
		_enabled = enabled;
		_margin_ns = enabled ? margin_ms * ms_ns : 0;
		_max_ttl_ns = enabled ? max_ttl_ms * ms_ns : 0;
		_boot_ns = now;
		_r.clear();
		_members.clear();
	}
	write_fence::authority_set_enabled(enabled);
	return true;
}

bool write_promise::enabled() {
	guard g(&_m);
	return _enabled;
}

void write_promise::set_role_probe(bool (*is_slave)(int partition)) {
	guard g(&_m);
	_is_slave = is_slave ? is_slave : slave_always;
}

uint64_t write_promise::_quiet_until_locked() {
	return _boot_ns + _max_ttl_ns + _margin_ns;
}

write_promise::status write_promise::_status_locked(const rstate& r, uint64_t now) {
	status s;
	s.st = r.st;
	s.intent = r.intent;
	s.term_next = r.term_next;
	s.have_promise = r.have_end;
	uint64_t until = _quiet_until_locked();
	if (r.have_end && r.end_ns > until) {
		until = r.end_ns;
	}
	s.remaining_ms = (now == write_fence::authority_clock_failed) ? max_ms : (now >= until ? 0 : (until - now + ms_ns - 1) / ms_ns);
	s.promotable = (r.st == st_committed || r.st == st_promoted) && s.remaining_ms == 0;
	return s;
}

bool write_promise::promise(uint32_t partition, uint64_t term, uint64_t generation, uint64_t ttl_ms, std::string& why) {
	// the floor is read before our lock (write_fence has its own locks; never nested)
	uint64_t ft = 0, fg = 0;
	const bool have_floor = write_fence::authority_floor(partition, ft, fg);
	bool (*probe)(int);
	{
		guard g(&_m);
		probe = _is_slave;
	}
	const bool slave = probe(static_cast<int>(partition));
	// the receive point: read as late as possible before the record
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	if (!slave) {
		why = "not a slave of this partition";
		return false;
	}
	if (!have_floor) {
		why = "no floor from the operator yet";
		return false;
	}
	// the floor the operator gives fences by TERM; the membership generation
	// moves with the successor set and is not part of it (a generation change
	// must not refuse the master's forwards or its renewals in between)
	(void) fg;
	(void) generation;
	if (term != ft) {
		why = "term does not match the floor";
		return false;
	}
	if (ttl_ms == 0 || ttl_ms * ms_ns > _max_ttl_ns) {
		why = "ttl outside the configured maximum";
		return false;
	}
	rstate& r = _r[partition];
	if (r.st != st_following) {
		why = "not following (preparing, committed or promoted)";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	if (now == write_fence::authority_clock_failed) {
		why = "the authority clock cannot be read";
		return false;
	}
	// recorded BEFORE the reply is sent; never shortens an earlier promise
	const uint64_t end = now + ttl_ms * ms_ns + _margin_ns;
	if (!r.have_end || end > r.end_ns) {
		r.end_ns = end;
	}
	r.have_end = true;
	return true;
}

bool write_promise::prepare(uint32_t partition, uint64_t intent, uint64_t term_next, status& out, std::string& why) {
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	rstate& r = _r[partition];
	if (r.st == st_following) {
		r.st = st_preparing;
		r.intent = intent;
		r.term_next = term_next;
	} else if (!(r.st == st_preparing && r.intent == intent)) {
		out = _status_locked(r, now);
		why = "another intent is in progress or the node is already committed / promoted";
		return false;
	}
	out = _status_locked(r, now);
	return true;
}

bool write_promise::commit(uint32_t partition, uint64_t intent, status& out, std::string& why) {
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	rstate& r = _r[partition];
	if (r.intent != intent || (r.st != st_preparing && r.st != st_committed && r.st != st_promoted)) {
		out = _status_locked(r, now);
		why = "not preparing this intent";
		return false;
	}
	if (r.st == st_preparing) {
		r.st = st_committed;
	}
	out = _status_locked(r, now);
	return true;
}

bool write_promise::cancel(uint32_t partition, uint64_t intent, status& out, std::string& why) {
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	rstate& r = _r[partition];
	if (r.st == st_preparing && r.intent == intent) {
		r.st = st_following;		// terminal CAS said cancelled: promising resumes
		r.intent = 0;
		r.term_next = 0;
	} else if (r.st == st_following && r.intent == 0) {
		// already cancelled / never prepared: nothing to undo
	} else {
		out = _status_locked(r, now);
		why = "committed, promoted, or another intent: a terminal decision does not reverse";
		return false;
	}
	out = _status_locked(r, now);
	return true;
}

write_promise::status write_promise::get_status(uint32_t partition) {
	guard g(&_m);
	const uint64_t now = write_fence::authority_now_ns();
	std::map<uint32_t, rstate>::const_iterator it = _r.find(partition);
	if (it == _r.end()) {
		return _status_locked(rstate(), now);
	}
	return _status_locked(it->second, now);
}

bool write_promise::may_promote(uint32_t partition, std::string& why) {
	guard g(&_m);
	if (!_enabled) {
		return true;
	}
	rstate& r = _r[partition];
	if (r.st == st_promoted) {
		return true;
	}
	if (r.st != st_committed) {
		why = "the promotion intent is not committed on this node";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	const status s = _status_locked(r, now);
	if (!s.promotable) {
		char b[160];
		snprintf(b, sizeof(b), "the last promise to the old master / the restart quiet time has not passed yet (%llu ms left)",
			static_cast<unsigned long long>(s.remaining_ms));
		why = b;
		return false;
	}
	r.st = st_promoted;
	return true;
}

void write_promise::note_role(uint32_t partition, bool master) {
	if (master) {
		return;
	}
	{
		guard g(&_m);
		std::map<uint32_t, rstate>::iterator it = _r.find(partition);
		if (it != _r.end() && it->second.st == st_promoted) {
			it->second = rstate();		// demoted: a follower again; promises resume
		}
		_members.erase(partition);		// no longer asks for promises for a partition it does not master
	}
	// and the authority it held as that master ends with the role
	uint64_t gt = 0, gg = 0, rem = 0;
	bool gsolo = false;
	if (write_fence::authority_info(partition, gt, gg, gsolo, rem)) {
		std::string w;
		write_fence::authority_revoke(partition, gt, gg, w);
	}
}

bool write_promise::set_floor(uint32_t partition, uint64_t term, uint64_t generation, std::string& why) {
	if (!enabled()) {
		why = "write authority is off";
		return false;
	}
	write_fence::authority_set_floor(partition, term, generation);
	return true;
}

static std::string node_identity() {
	char host[256];
	if (gethostname(host, sizeof(host)) != 0) {
		return "node";
	}
	host[sizeof(host) - 1] = '\0';
	return host;
}

bool write_promise::set_members(uint32_t partition, uint64_t term, uint64_t generation, uint64_t ttl_ms,
		uint64_t renew_ms, const std::vector<std::string>& successors, std::string& why) {
	if (successors.empty() || ttl_ms == 0 || renew_ms == 0 || renew_ms >= ttl_ms || ttl_ms > max_ms) {
		why = "members need successors and 0 < renew < ttl";
		return false;
	}
	{
		guard g(&_m);
		if (!_enabled) {
			why = "write authority is off";
			return false;
		}
		if (_boot_ns == 0) {
			why = "not configured";
			return false;
		}
		std::map<uint32_t, members>::const_iterator it = _members.find(partition);
		if (it != _members.end()) {
			const members& o = it->second;
			if (term < o.term || (term == o.term && generation < o.generation)) {
				why = "older term / generation than the membership held";
				return false;
			}
			if (term == o.term && generation == o.generation && (o.solo || o.successors != successors)) {
				why = "the same generation with another membership";
				return false;
			}
		}
	}
	char boot[64];
	snprintf(boot, sizeof(boot), "%llu", static_cast<unsigned long long>(_boot_ns));
	write_fence::authority_ensure_identity(partition, node_identity(), boot, "c");
	// leaving solo: the unlimited grant of the older generation must not survive,
	// else a promotion of a successor would not end this master's authority
	uint64_t gt = 0, gg = 0, rem = 0;
	bool gsolo = false;
	if (write_fence::authority_info(partition, gt, gg, gsolo, rem) && gsolo && (term > gt || generation > gg)) {
		std::string w;
		write_fence::authority_revoke(partition, gt, gg, w);
	}
	{
		guard g(&_m);
		members m;
		m.partition = partition;
		m.term = term;
		m.generation = generation;
		m.solo = false;
		m.ttl_ms = ttl_ms;
		m.renew_ms = renew_ms;
		m.successors = successors;
		_members[partition] = m;
	}
	return true;
}

bool write_promise::set_solo(uint32_t partition, uint64_t term, uint64_t generation, std::string& why) {
	{
		guard g(&_m);
		if (!_enabled) {
			why = "write authority is off";
			return false;
		}
		std::map<uint32_t, members>::const_iterator it = _members.find(partition);
		if (it != _members.end()) {
			const members& o = it->second;
			if (term < o.term || (term == o.term && generation < o.generation)) {
				why = "older term / generation than the membership held";
				return false;
			}
			if (term == o.term && generation == o.generation && !o.solo) {
				why = "the same generation with another membership";
				return false;
			}
		}
	}
	char boot[64];
	snprintf(boot, sizeof(boot), "%llu", static_cast<unsigned long long>(_boot_ns));
	write_fence::authority_ensure_identity(partition, node_identity(), boot, "c");
	const uint64_t nonce = write_fence::authority_begin_request(partition);
	write_fence::authority_grant g;
	g.partition = partition;
	g.term = term;
	g.generation = generation;
	write_fence::authority_identity(g.pod_uid, g.boot_id, g.copy_id);
	g.nonce = nonce;
	g.solo = true;
	if (!write_fence::authority_apply_grant(g, why)) {
		return false;
	}
	guard gd(&_m);
	members m;
	m.partition = partition;
	m.term = term;
	m.generation = generation;
	m.solo = true;
	_members[partition] = m;
	return true;
}

bool write_promise::get_members(uint32_t partition, members& out) {
	guard g(&_m);
	std::map<uint32_t, members>::const_iterator it = _members.find(partition);
	if (it == _members.end()) {
		return false;
	}
	out = it->second;
	return true;
}

std::vector<uint32_t> write_promise::member_partitions() {
	guard g(&_m);
	std::vector<uint32_t> v;
	for (std::map<uint32_t, members>::const_iterator it = _members.begin(); it != _members.end(); it++) {
		v.push_back(it->first);
	}
	return v;
}

uint64_t write_promise::begin_round(const members& m) {
	if (m.solo) {
		return 0;
	}
	return write_fence::authority_begin_request(m.partition);
}

bool write_promise::finish_round(const members& m, uint64_t nonce, size_t promised, std::string& why) {
	if (m.solo || nonce == 0) {
		why = "no round";
		return false;
	}
	if (promised != m.successors.size()) {
		why = "not every successor promised";
		return false;
	}
	write_fence::authority_grant g;
	g.partition = m.partition;
	g.term = m.term;
	g.generation = m.generation;
	write_fence::authority_identity(g.pod_uid, g.boot_id, g.copy_id);
	g.nonce = nonce;
	g.ttl_ns = m.ttl_ms * ms_ns;
	g.solo = false;
	return write_fence::authority_apply_grant(g, why);
}

void write_promise::reset_for_test() {
	guard g(&_m);
	_enabled = false;
	_margin_ns = _max_ttl_ns = _boot_ns = 0;
	_is_slave = slave_always;
	_r.clear();
	_members.clear();
}

}	// namespace flare
}	// namespace gree
