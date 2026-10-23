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
uint64_t boot_ns_for_identity = 0;
void default_identity(std::string& boot, std::string& copy) {
	char b[64];
	snprintf(b, sizeof(b), "%llu", static_cast<unsigned long long>(boot_ns_for_identity));
	boot = b;
	copy.clear();		// no copy id known: undetermined (authority ON refuses everything bound to it)
}

bool identity_known(const std::string& boot, const std::string& copy, std::string& why) {
	if (boot.empty() || copy.empty()) {
		why = "this node's copy / boot identity is undetermined (no persistent copy id): refusing";
		return false;
	}
	return true;
}
}

pthread_mutex_t write_promise::_m = PTHREAD_MUTEX_INITIALIZER;
bool write_promise::_enabled = false;
uint64_t write_promise::_margin_ns = 0;
uint64_t write_promise::_max_ttl_ns = 0;
uint64_t write_promise::_boot_ns = 0;
bool (*write_promise::_is_slave)(int) = slave_always;
std::map<uint32_t, write_promise::rstate> write_promise::_r;
std::map<uint32_t, write_promise::members> write_promise::_members;
std::map<uint32_t, write_promise::first_build> write_promise::_first;
void (*write_promise::_identity_probe)(std::string&, std::string&) = default_identity;

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
		boot_ns_for_identity = now;
		_r.clear();
		_members.clear();
		_first.clear();
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

void write_promise::_identity_locked(std::string& boot, std::string& copy) {
	_identity_probe(boot, copy);
}

void write_promise::identity(std::string& boot, std::string& copy) {
	guard g(&_m);
	_identity_locked(boot, copy);
}

static std::string node_identity();

// The authority engine's identity of this node is the REAL one: this host (the pod), the flared
// process boot id and the storage's persistent copy id. When the copy (or the process) is not the
// one the memberships were bound to — a snapshot swap, a replacement — every grant bound to the
// old identity is void (authority_ensure_identity clears them) and the memberships are re-bound;
// the operator's acknowledgement was for the old identity and is not inherited (it reads the
// bound identity back). Called with `_m` held.
void write_promise::_rebind_locked() {
	std::string boot, copy;
	_identity_locked(boot, copy);
	std::string unused;
	if (!identity_known(boot, copy, unused)) {
		return;		// undetermined: nothing is re-bound to it (and nothing is granted for it)
	}
	bool changed = false;
	for (std::map<uint32_t, members>::iterator it = _members.begin(); it != _members.end(); it++) {
		if (it->second.boot != boot || it->second.copy != copy) {
			changed = true;
		}
	}
	if (!changed) {
		return;
	}
	const std::string host = node_identity();
	for (std::map<uint32_t, members>::iterator it = _members.begin(); it != _members.end(); it++) {
		write_fence::authority_ensure_identity(it->first, host, boot, copy);
		it->second.boot = boot;
		it->second.copy = copy;
	}
}

void write_promise::set_identity_probe(void (*probe)(std::string&, std::string&)) {
	guard g(&_m);
	_identity_probe = probe ? probe : default_identity;
}

// a prepared / committed intent belongs to the copy it was prepared for: another copy
// (a snapshot swap, a replacement) never inherits it. The promises already issued keep their end.
void write_promise::_revalidate_locked(rstate& r, const std::string& boot, const std::string& copy) {
	if ((r.st == st_preparing || r.st == st_committed) && (r.sc.boot != boot || r.sc.copy != copy)) {
		r.st = st_following;
		r.sc = scope();
	}
}

write_promise::status write_promise::_status_locked(const rstate& r, uint64_t now, const std::string& boot, const std::string& copy) {
	status s;
	s.st = r.st;
	s.intent = r.sc.intent;
	s.term_next = r.sc.term_next;
	s.generation = r.sc.generation;
	s.boot = r.st == st_following ? boot : r.sc.boot;
	s.copy = r.st == st_following ? copy : r.sc.copy;
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
	std::string boot, copy;
	identity(boot, copy);
	// the receive point: read as late as possible before the record
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	if (!identity_known(boot, copy, why)) {
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
	_revalidate_locked(r, boot, copy);
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

bool write_promise::prepare(uint32_t partition, const scope& sc, status& out, std::string& why) {
	std::string boot, copy;
	identity(boot, copy);
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	if (!identity_known(boot, copy, why)) {
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	rstate& r = _r[partition];
	_revalidate_locked(r, boot, copy);
	if (sc.intent == 0 || sc.term_next == 0) {
		out = _status_locked(r, now, boot, copy);
		why = "an intent needs an id and a next term";
		return false;
	}
	if (sc.boot != boot || sc.copy != copy) {
		out = _status_locked(r, now, boot, copy);
		why = "the intent is bound to another incarnation or copy of this node";
		return false;
	}
	if (r.st == st_following) {
		r.st = st_preparing;
		r.sc = sc;
	} else if (!(r.st == st_preparing && r.sc == sc)) {
		out = _status_locked(r, now, boot, copy);
		why = "another intent / scope is in progress or the node is already committed / promoted";
		return false;
	}
	out = _status_locked(r, now, boot, copy);
	return true;
}

bool write_promise::commit(uint32_t partition, const scope& sc, status& out, std::string& why) {
	std::string boot, copy;
	identity(boot, copy);
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	if (!identity_known(boot, copy, why)) {
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	rstate& r = _r[partition];
	_revalidate_locked(r, boot, copy);
	if (!(r.sc == sc) || (r.st != st_preparing && r.st != st_committed && r.st != st_promoted)) {
		out = _status_locked(r, now, boot, copy);
		why = "not preparing this intent (id, term, generation and incarnation must all match)";
		return false;
	}
	if (r.st == st_preparing) {
		r.st = st_committed;
	}
	out = _status_locked(r, now, boot, copy);
	return true;
}

bool write_promise::cancel(uint32_t partition, const scope& sc, status& out, std::string& why) {
	std::string boot, copy;
	identity(boot, copy);
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	if (!identity_known(boot, copy, why)) {
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	rstate& r = _r[partition];
	_revalidate_locked(r, boot, copy);
	if (r.st == st_preparing && r.sc == sc) {
		r.st = st_following;		// terminal CAS said cancelled: promising resumes
		r.sc = scope();
	} else if (r.st == st_following) {
		// already cancelled / never prepared: nothing to undo
	} else {
		out = _status_locked(r, now, boot, copy);
		why = "committed, promoted, or another scope: a terminal decision does not reverse and an old cancel releases nothing";
		return false;
	}
	out = _status_locked(r, now, boot, copy);
	return true;
}

write_promise::status write_promise::get_status(uint32_t partition) {
	std::string boot, copy;
	identity(boot, copy);
	guard g(&_m);
	const uint64_t now = write_fence::authority_now_ns();
	std::map<uint32_t, rstate>::iterator it = _r.find(partition);
	if (it == _r.end()) {
		return _status_locked(rstate(), now, boot, copy);
	}
	_revalidate_locked(it->second, boot, copy);
	return _status_locked(it->second, now, boot, copy);
}

bool write_promise::may_promote(uint32_t partition, std::string& why) {
	std::string boot, copy;
	identity(boot, copy);
	guard g(&_m);
	if (!_enabled) {
		return true;
	}
	if (!identity_known(boot, copy, why)) {
		return false;
	}
	rstate& r = _r[partition];
	_revalidate_locked(r, boot, copy);
	if (r.st == st_promoted) {
		return true;
	}
	if (r.st != st_committed) {
		why = "the promotion intent is not committed on this node (for this incarnation and copy)";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	const status s = _status_locked(r, now, boot, copy);
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

bool write_promise::allow_first_build(uint32_t partition, const std::string& boot, const std::string& copy, std::string& why) {
	std::string cb, cc;
	identity(cb, cc);
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	if (!identity_known(cb, cc, why)) {
		return false;
	}
	if (boot != cb || copy != cc) {
		why = "the first-build proof is for another incarnation or copy of this node";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	if (now == write_fence::authority_clock_failed) {
		why = "the authority clock cannot be read";
		return false;
	}
	first_build f;
	f.boot = boot;
	f.copy = copy;
	f.until_ns = now + 10 * (_max_ttl_ns + _margin_ns);		// the pass that proved it commits the map right after
	_first[partition] = f;
	return true;
}

bool write_promise::may_first_build(uint32_t partition, std::string& why) {
	std::string boot, copy;
	identity(boot, copy);
	guard g(&_m);
	if (!_enabled) {
		return true;
	}
	if (!identity_known(boot, copy, why)) {
		return false;
	}
	std::map<uint32_t, first_build>::iterator it = _first.find(partition);
	if (it == _first.end()) {
		why = "an existing copy returning from Proxy to master needs the promotion intent (no first-build proof)";
		return false;
	}
	const uint64_t now = write_fence::authority_now_ns();
	const bool ok = now != write_fence::authority_clock_failed && now < it->second.until_ns
		&& it->second.boot == boot && it->second.copy == copy;
	_first.erase(it);		// used or void either way
	if (!ok) {
		why = "the first-build proof expired or belongs to another incarnation / copy";
	}
	return ok;
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
		_first.erase(partition);
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

// The membership of a partition changes under ONE critical section (_m, then write_fence's locks:
// the order is fixed, nothing takes them the other way round): the check, the invalidation of
// the old grant, of every pending round nonce and of the old apply sections (authority_revoke
// drains them), and the installation of the new record. The operator's ACK of a membership (the
// return of true) therefore means: no grant of an older (term, generation) is valid any more, no
// round sent for it can still be applied (finish_round compares under the same lock), and no
// write admitted under it is still applying. A newcomer successor never gave a promise behind a
// grant that is gone; the next grant needs ALL members of the new generation.
// Called with `_m` held; `old` is the record replaced (if any).
static bool lex_less(uint64_t t1, uint64_t g1, uint64_t t2, uint64_t g2) {
	return t1 < t2 || (t1 == t2 && g1 < g2);
}

// (term, generation) is compared LEXICOGRAPHICALLY everywhere: the generation is independent
// across terms, so (4, 9) is OLDER than (5, 8). A record older than the floor or than the grant
// held is refused (nothing is revoked: a stale command cannot stop a healthy master).
static bool refuse_stale_authority(uint32_t partition, uint64_t term, uint64_t generation, std::string& why) {
	uint64_t ft = 0, fg = 0;
	if (write_fence::authority_floor(partition, ft, fg) && lex_less(term, generation, ft, fg)) {
		why = "older term / generation than the floor";
		return true;
	}
	uint64_t gt = 0, gg = 0, rem = 0;
	bool gsolo = false;
	if (write_fence::authority_info(partition, gt, gg, gsolo, rem) && lex_less(term, generation, gt, gg)) {
		why = "older term / generation than the grant held";
		return true;
	}
	return false;
}

static void invalidate_older_authority(uint32_t partition, uint64_t term, uint64_t generation, bool had_old, uint64_t old_term, uint64_t old_gen) {
	std::string w;
	uint64_t gt = 0, gg = 0, rem = 0;
	bool gsolo = false;
	uint64_t rt = 0, rg = 0;
	bool any = false;
	if (had_old) {
		rt = old_term;
		rg = old_gen;
		any = true;
	}
	if (write_fence::authority_info(partition, gt, gg, gsolo, rem) && lex_less(gt, gg, term, generation)) {
		if (!any || lex_less(rt, rg, gt, gg)) {
			rt = gt;
			rg = gg;
		}
		any = true;
	}
	if (any && lex_less(rt, rg, term, generation)) {
		write_fence::authority_revoke(partition, rt, rg, w);
	}
}

bool write_promise::set_members(uint32_t partition, uint64_t term, uint64_t generation, uint64_t ttl_ms,
		uint64_t renew_ms, const std::vector<std::string>& successors, std::string& why) {
	if (successors.empty() || ttl_ms == 0 || renew_ms == 0 || renew_ms >= ttl_ms || ttl_ms > max_ms) {
		why = "members need successors and 0 < renew < ttl";
		return false;
	}
	std::string host = node_identity();
	guard g(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	if (_boot_ns == 0) {
		why = "not configured";
		return false;
	}
	_rebind_locked();
	bool had_old = false;
	uint64_t ot = 0, og = 0;
	std::map<uint32_t, members>::const_iterator it = _members.find(partition);
	if (it != _members.end()) {
		const members& o = it->second;
		if (term < o.term || (term == o.term && generation < o.generation)) {
			why = "older term / generation than the membership held";
			return false;
		}
		if (term == o.term && generation == o.generation) {
			if (o.solo || o.successors != successors) {
				why = "the same generation with another membership";
				return false;
			}
			// the same record again: nothing changes (and no grant is touched), but its timing may
			if (o.ttl_ms != ttl_ms || o.renew_ms != renew_ms) {
				why = "the same generation with other timing";
				return false;
			}
			return true;
		}
		had_old = true;
		ot = o.term;
		og = o.generation;
	}
	std::string idboot, idcopy;
	_identity_locked(idboot, idcopy);
	if (!identity_known(idboot, idcopy, why)) {
		return false;
	}
	write_fence::authority_ensure_identity(partition, host, idboot, idcopy);
	if (refuse_stale_authority(partition, term, generation, why)) {
		return false;
	}
	// EVERY change (solo -> replicated, replicated -> replicated, a new term) ends the older authority first
	invalidate_older_authority(partition, term, generation, had_old, ot, og);
	members m;
	m.partition = partition;
	m.term = term;
	m.generation = generation;
	m.solo = false;
	m.ttl_ms = ttl_ms;
	m.renew_ms = renew_ms;
	m.successors = successors;
	m.boot = idboot;
	m.copy = idcopy;
	_members[partition] = m;
	return true;
}

bool write_promise::set_solo(uint32_t partition, uint64_t term, uint64_t generation, std::string& why) {
	std::string host = node_identity();
	guard gd(&_m);
	if (!_enabled) {
		why = "write authority is off";
		return false;
	}
	_rebind_locked();
	std::map<uint32_t, members>::const_iterator it = _members.find(partition);
	bool again = false;		// the same solo record, its grant gone (a re-bound identity): grant again
	if (it != _members.end()) {
		const members& o = it->second;
		if (term < o.term || (term == o.term && generation < o.generation)) {
			why = "older term / generation than the membership held";
			return false;
		}
		if (term == o.term && generation == o.generation) {
			if (!o.solo) {
				why = "the same generation with another membership";
				return false;
			}
			uint64_t gt = 0, gg = 0, rem = 0;
			bool gsolo = false;
			if (write_fence::authority_info(partition, gt, gg, gsolo, rem) && gsolo && gt == term && gg == generation) {
				return true;
			}
			again = true;
		}
	}
	std::string idboot, idcopy;
	_identity_locked(idboot, idcopy);
	if (!identity_known(idboot, idcopy, why)) {
		return false;
	}
	write_fence::authority_ensure_identity(partition, host, idboot, idcopy);
	if (refuse_stale_authority(partition, term, generation, why)) {
		return false;
	}
	if (it != _members.end() && !again) {
		// the replicated record's rounds and grant end before the unlimited grant begins
		invalidate_older_authority(partition, term, generation, true, it->second.term, it->second.generation);
	}
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
	members m;
	m.partition = partition;
	m.term = term;
	m.generation = generation;
	m.solo = true;
	m.boot = idboot;
	m.copy = idcopy;
	_members[partition] = m;
	return true;
}

bool write_promise::get_members(uint32_t partition, members& out) {
	guard g(&_m);
	_rebind_locked();
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
	guard g(&_m);
	_rebind_locked();
	std::map<uint32_t, members>::const_iterator it = _members.find(m.partition);
	if (it == _members.end() || it->second.solo || it->second.term != m.term || it->second.generation != m.generation) {
		return 0;		// a round is sent only for the membership in force
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
	// the check against the CURRENT membership and the application of the grant are one critical
	// section with set_members / set_solo / note_role (a round of an older generation, a delayed
	// reply, is refused; there is no window between the check and the application)
	guard gd(&_m);
	_rebind_locked();
	{
		std::string b, c;
		_identity_locked(b, c);
		if (!identity_known(b, c, why)) {
			return false;
		}
	}
	std::map<uint32_t, members>::const_iterator it = _members.find(m.partition);
	if (it == _members.end() || it->second.solo || it->second.term != m.term || it->second.generation != m.generation
			|| it->second.successors != m.successors || it->second.ttl_ms != m.ttl_ms || it->second.boot != m.boot
			|| it->second.copy != m.copy) {
		why = "the membership changed since this round was sent";
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
	_identity_probe = default_identity;
	_r.clear();
	_members.clear();
	_first.clear();
}

}	// namespace flare
}	// namespace gree
