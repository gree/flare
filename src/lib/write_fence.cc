/**
 *	write_fence.cc
 *
 *	implementation of gree::flare::write_fence (see the header)
 */
#include "write_fence.h"

#include <stdio.h>

namespace gree {
namespace flare {

static time_t default_clock() {
	return time(NULL);
}

static int (*gettime_fn)(clockid_t, struct timespec*) = clock_gettime;

static uint64_t default_boottime_ns() {
	struct timespec ts;
	ts.tv_sec = 0;
	ts.tv_nsec = 0;
	if (gettime_fn(CLOCK_BOOTTIME, &ts) != 0 || ts.tv_sec < 0 || ts.tv_nsec < 0) {
		return write_fence::authority_clock_failed;		// fail closed
	}
	return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL + static_cast<uint64_t>(ts.tv_nsec);
}

static const size_t authority_max_pending = 64;
static volatile uint64_t drain_waits = 0;

pthread_mutex_t	write_fence::_mutex = PTHREAD_MUTEX_INITIALIZER;
#ifdef PTHREAD_RWLOCK_WRITER_NONRECURSIVE_INITIALIZER_NP
// a waiting change of authority must not starve behind a stream of writes
pthread_rwlock_t	write_fence::_apply_rw = PTHREAD_RWLOCK_WRITER_NONRECURSIVE_INITIALIZER_NP;
#else
pthread_rwlock_t	write_fence::_apply_rw = PTHREAD_RWLOCK_INITIALIZER;
#endif
bool			write_fence::_armed = false;
std::string		write_fence::_token;
time_t			write_fence::_expires = 0;
uint64_t		write_fence::_in_flight = 0;
uint64_t		write_fence::_refused = 0;
uint64_t		write_fence::_generation = 0;
time_t			(*write_fence::_clock)() = default_clock;
void			(*write_fence::_entry_hook)() = NULL;
void			(*write_fence::_admit_hook)() = NULL;
bool			write_fence::_auth_enabled = false;
bool			write_fence::_auth_identity_set = false;
uint32_t		write_fence::_auth_partition = 0;
std::string		write_fence::_auth_pod_uid;
std::string		write_fence::_auth_boot_id;
std::string		write_fence::_auth_copy_id;
uint64_t		write_fence::_auth_next_nonce = 1;
std::map<uint32_t, write_fence::part_state>	write_fence::_auth_parts;
std::set<uint32_t>	write_fence::_auth_registered;
uint64_t		write_fence::_auth_refused = 0;
uint64_t		(*write_fence::_auth_clock)() = default_boottime_ns;

namespace {
class exclusive {
public:
	explicit exclusive(pthread_rwlock_t* l, bool take): _l(take ? l : NULL) {
		if (_l && pthread_rwlock_trywrlock(_l) != 0) {
			// a write is in its apply section: this change of authority waits for it
			__sync_fetch_and_add(&drain_waits, 1);
			pthread_rwlock_wrlock(_l);
		}
	}
	~exclusive() { if (_l) pthread_rwlock_unlock(_l); }
private:
	pthread_rwlock_t* _l;
};
class scoped {
public:
	explicit scoped(pthread_mutex_t* m): _m(m) { pthread_mutex_lock(_m); }
	~scoped() { pthread_mutex_unlock(_m); }
private:
	pthread_mutex_t* _m;
};
}

bool write_fence::_active_locked(time_t now) {
	if (_armed && now >= _expires) {
		// the operator did not re-arm in time: release by itself
		_armed = false;
		_token.clear();
		_expires = 0;
	}
	return _armed;
}

bool write_fence::arm(const std::string& token, uint32_t ttl_sec, std::string& why) {
	if (token.empty() || token.find_first_of(" \t\r\n") != std::string::npos) {
		why = "invalid token";
		return false;
	}
	if (ttl_sec == 0 || ttl_sec > 3600) {
		why = "ttl must be 1..3600 seconds";
		return false;
	}
	scoped l(&_mutex);
	const time_t now = _clock();
	const bool was_active = _active_locked(now);
	if (was_active && _token != token) {
		why = "fenced by another token";
		return false;
	}
	if (!was_active) {
		// a new continuous fence (first arm, or after a release / a lapse)
		_generation++;
	}
	_armed = true;
	_token = token;
	_expires = now + ttl_sec;
	return true;
}

bool write_fence::release(const std::string& token) {
	scoped l(&_mutex);
	if (!_active_locked(_clock())) {
		return true;
	}
	if (_token != token) {
		return false;
	}
	_armed = false;
	_token.clear();
	_expires = 0;
	return true;
}

bool write_fence::active() {
	scoped l(&_mutex);
	return _active_locked(_clock());
}

std::string write_fence::token() {
	scoped l(&_mutex);
	return _active_locked(_clock()) ? _token : std::string();
}

uint32_t write_fence::remaining_sec() {
	scoped l(&_mutex);
	const time_t now = _clock();
	if (!_active_locked(now)) {
		return 0;
	}
	return static_cast<uint32_t>(_expires - now);
}

uint64_t write_fence::in_flight() {
	scoped l(&_mutex);
	return _in_flight;
}

uint64_t write_fence::refused() {
	scoped l(&_mutex);
	return _refused;
}

uint64_t write_fence::generation() {
	scoped l(&_mutex);
	return _generation;
}

write_fence::status write_fence::snapshot() {
	scoped l(&_mutex);
	const time_t now = _clock();
	status s;
	s.active = _active_locked(now);
	s.token = s.active ? _token : std::string();
	s.remaining_sec = s.active ? static_cast<uint32_t>(_expires - now) : 0;
	s.in_flight = _in_flight;
	s.refused = _refused;
	s.generation = _generation;
	return s;
}

write_fence::entry::entry() {
	void (*hook)() = NULL;
	{
		scoped l(&_mutex);
		this->_no_authority = false;
		this->_bound = false;
		this->_bound_replica = false;
		this->_applying = false;
		this->_bound_solo = false;
		this->_bound_partition = 0;
		this->_bound_serial = 0;
		this->_bound_deadline = 0;
		this->_bound_term = 0;
		this->_bound_gen = 0;
		this->_fenced = _active_locked(_clock());
		if (this->_fenced) {
			_refused++;
		} else {
			// the fence only; the write authority is taken where the entry
			// says what it is (admit_master / admit_replica)
			_in_flight++;
			hook = _entry_hook;
		}
	}
	if (hook != NULL) {
		hook();
	}
}

write_fence::entry::~entry() {
	if (this->_fenced) {
		return;
	}
	this->apply_end();
	scoped l(&_mutex);
	_in_flight--;
}

// an admitted entry that the authority engine refuses leaves the in-flight
// count and reads as fenced from now on
void write_fence::_refuse_admission_locked(entry& e) {
	e._fenced = true;
	e._no_authority = true;
	e._bound = false;
	_in_flight--;
	_refused++;
	_auth_refused++;
}

bool write_fence::entry::admit_master(int partition) {
	const bool ok = this->_admit_master(partition);
	if (ok && this->_bound) {
		void (*hook)() = NULL;
		{
			scoped l(&_mutex);
			hook = _admit_hook;
		}
		if (hook != NULL) {
			hook();
		}
	}
	return ok;
}

bool write_fence::entry::admit_replica(int partition, const std::string& tag) {
	const bool ok = this->_admit_replica(partition, tag);
	if (ok && this->_bound) {
		void (*hook)() = NULL;
		{
			scoped l(&_mutex);
			hook = _admit_hook;
		}
		if (hook != NULL) {
			hook();
		}
	}
	return ok;
}

bool write_fence::entry::_admit_master(int partition) {
	if (this->_fenced) {
		return false;
	}
	scoped l(&_mutex);
	if (!_auth_enabled) {
		return true;
	}
	if (partition >= 0) {
		std::map<uint32_t, part_state>::iterator it = _auth_parts.find(static_cast<uint32_t>(partition));
		if (it != _auth_parts.end() && _authority_valid_locked(it->second, _auth_clock())) {
			const part_state& ps = it->second;
			this->_bound = true;
			this->_bound_replica = false;
			this->_bound_partition = static_cast<uint32_t>(partition);
			this->_bound_serial = ps.serial;
			this->_bound_solo = ps.solo;
			this->_bound_deadline = ps.deadline;
			this->_bound_term = ps.term;
			this->_bound_gen = ps.gen;
			return true;
		}
	}
	_refuse_admission_locked(*this);
	return false;
}

bool write_fence::entry::_admit_replica(int partition, const std::string& tag) {
	if (this->_fenced) {
		return false;
	}
	uint32_t tp = 0;
	uint64_t tt = 0, tg = 0;
	bool raise = false;
	for (;;) {
		{
			// a raise of the floor drains the apply sections first
			exclusive x(&_apply_rw, raise);
			scoped l(&_mutex);
			if (!_auth_enabled) {
				return true;
			}
			if (partition < 0 || !authority_parse_tag(tag, tp, tt, tg) || tp != static_cast<uint32_t>(partition)) {
				_refuse_admission_locked(*this);
				return false;
			}
			part_state& ps = _auth_parts[tp];
			// a node that is the master of the partition takes no replica change
			if (_authority_valid_locked(ps, _auth_clock())) {
				_refuse_admission_locked(*this);
				return false;
			}
			// no floor yet: the first token is NOT accepted (an old master's forward
			// could be it). The operator gives the floor before the engine matters
			// (authority_set_floor / `authority floor`), design §13.
			if (!ps.floor_set || tt < ps.floor_term || (tt == ps.floor_term && tg < ps.floor_gen)) {
				_refuse_admission_locked(*this);
				return false;
			}
			const bool higher = tt > ps.floor_term || (tt == ps.floor_term && tg > ps.floor_gen);
			if (higher && !raise) {
				raise = true;
				continue;
			}
			if (higher) {
				ps.floor_set = true;
				ps.floor_term = tt;
				ps.floor_gen = tg;
				ps.floor_serial++;
			}
			this->_bound = true;
			this->_bound_replica = true;
			this->_bound_partition = tp;
			this->_bound_serial = ps.floor_serial;
			this->_bound_term = tt;
			this->_bound_gen = tg;
			return true;
		}
	}
}

std::string write_fence::entry::authority_tag() const {
	if (!this->_bound || this->_bound_replica) {
		return std::string();
	}
	char buf[96];
	snprintf(buf, sizeof(buf), "%u:%llu:%llu", this->_bound_partition,
		static_cast<unsigned long long>(this->_bound_term), static_cast<unsigned long long>(this->_bound_gen));
	return buf;
}

bool write_fence::authority_parse_tag(const std::string& tag, uint32_t& partition, uint64_t& term, uint64_t& generation) {
	unsigned long long p = 0, t = 0, g = 0;
	int n = 0;
	if (tag.empty() || tag.size() > 64 || sscanf(tag.c_str(), "%llu:%llu:%llu%n", &p, &t, &g, &n) != 3
			|| static_cast<size_t>(n) != tag.size() || p > 0xffffffffULL || tag.find_first_of("+- ") != std::string::npos) {
		return false;
	}
	partition = static_cast<uint32_t>(p);
	term = t;
	generation = g;
	return true;
}

// the authority this entry was admitted under is still the current one
// (no revoke / new term / generation / identity / engine switch since: the
// serial) and, for a master, its OWN deadline has not passed. A renewal of
// the same authority does not change the serial, and the entry never gets the
// new TTL. A replica entry is current while the partition's floor has not
// moved (floor_serial) and no master grant appeared.
bool write_fence::_bound_ok_locked(const entry& e, uint64_t now) {
	if (now == authority_clock_failed || !e._bound || !_auth_enabled) {
		return false;
	}
	std::map<uint32_t, part_state>::const_iterator it = _auth_parts.find(e._bound_partition);
	if (it == _auth_parts.end()) {
		return false;
	}
	const part_state& ps = it->second;
	if (e._bound_replica) {
		return ps.floor_serial == e._bound_serial && !_authority_valid_locked(ps, now);
	}
	return ps.have && ps.serial == e._bound_serial
		&& (e._bound_solo || now < e._bound_deadline) && _authority_valid_locked(ps, now);
}

bool write_fence::entry::ack_ok() {
	if (this->_fenced) {
		return false;
	}
	scoped l(&_mutex);
	if (!this->_bound && !_auth_enabled) {
		return true;
	}
	if (_bound_ok_locked(*this, _auth_clock())) {
		return true;
	}
	_auth_refused++;
	return false;
}

bool write_fence::entry::still_authorized() {
	if (this->_fenced) {
		return false;
	}
	scoped l(&_mutex);
	if (!this->_bound && !_auth_enabled) {
		return true;
	}
	if (_bound_ok_locked(*this, _auth_clock())) {
		return true;
	}
	_auth_refused++;
	return false;
}

bool write_fence::entry::apply_begin() {
	if (this->_fenced || this->_applying) {
		return false;
	}
	pthread_rwlock_rdlock(&_apply_rw);
	{
		scoped l(&_mutex);
		if ((!this->_bound && !_auth_enabled) || _bound_ok_locked(*this, _auth_clock())) {
			this->_applying = true;
			return true;
		}
		_auth_refused++;
	}
	pthread_rwlock_unlock(&_apply_rw);
	return false;
}

void write_fence::entry::apply_end() {
	if (this->_applying) {
		this->_applying = false;
		pthread_rwlock_unlock(&_apply_rw);
	}
}

bool write_fence::_authority_valid_locked(const part_state& ps, uint64_t now) {
	if (!ps.have) {
		return false;
	}
	if (now == authority_clock_failed) {
		return false;
	}
	return ps.solo || now < ps.deadline;
}

void write_fence::_clear_grant_locked(part_state& ps) {
	ps.have = false;
	ps.deadline = 0;
	ps.solo = false;
	ps.pending.clear();
	ps.serial++;
	ps.floor_serial++;
}

void write_fence::authority_set_enabled(bool on) {
	exclusive x(&_apply_rw, true);
	scoped l(&_mutex);
	_auth_enabled = on;
	for (std::map<uint32_t, part_state>::iterator it = _auth_parts.begin(); it != _auth_parts.end(); it++) {
		_clear_grant_locked(it->second);
	}
}

bool write_fence::authority_enabled() {
	scoped l(&_mutex);
	return _auth_enabled;
}

void write_fence::authority_set_identity(uint32_t partition, const std::string& pod_uid,
		const std::string& boot_id, const std::string& copy_id) {
	exclusive x(&_apply_rw, true);
	scoped l(&_mutex);
	const bool other = !_auth_identity_set || pod_uid != _auth_pod_uid || boot_id != _auth_boot_id || copy_id != _auth_copy_id;
	_auth_identity_set = true;
	_auth_partition = partition;
	_auth_pod_uid = pod_uid;
	_auth_boot_id = boot_id;
	_auth_copy_id = copy_id;
	_auth_registered.insert(partition);
	// a different identity never inherits a grant bound to the old one
	if (other) {
		for (std::map<uint32_t, part_state>::iterator it = _auth_parts.begin(); it != _auth_parts.end(); it++) {
			_clear_grant_locked(it->second);
		}
	}
	_clear_grant_locked(_auth_parts[partition]);
}

void write_fence::authority_ensure_identity(uint32_t partition, const std::string& pod_uid,
		const std::string& boot_id, const std::string& copy_id) {
	{
		scoped l(&_mutex);
		if (_auth_identity_set && pod_uid == _auth_pod_uid && boot_id == _auth_boot_id && copy_id == _auth_copy_id
				&& _auth_registered.count(partition) != 0) {
			return;
		}
	}
	exclusive x(&_apply_rw, true);
	scoped l(&_mutex);
	const bool other = !_auth_identity_set || pod_uid != _auth_pod_uid || boot_id != _auth_boot_id || copy_id != _auth_copy_id;
	_auth_identity_set = true;
	_auth_pod_uid = pod_uid;
	_auth_boot_id = boot_id;
	_auth_copy_id = copy_id;
	if (other) {
		for (std::map<uint32_t, part_state>::iterator it = _auth_parts.begin(); it != _auth_parts.end(); it++) {
			_clear_grant_locked(it->second);
		}
		_auth_registered.clear();
	}
	_auth_registered.insert(partition);
	_auth_parts[partition];
}

uint64_t write_fence::authority_now_ns() {
	scoped l(&_mutex);
	return _auth_clock();
}

bool write_fence::authority_info(uint32_t partition, uint64_t& term, uint64_t& generation, bool& solo, uint64_t& remaining_ns) {
	scoped l(&_mutex);
	std::map<uint32_t, part_state>::const_iterator it = _auth_parts.find(partition);
	const uint64_t now = _auth_clock();
	if (!_auth_enabled || it == _auth_parts.end() || !_authority_valid_locked(it->second, now)) {
		return false;
	}
	term = it->second.term;
	generation = it->second.gen;
	solo = it->second.solo;
	remaining_ns = solo ? 0 : it->second.deadline - now;
	return true;
}

void write_fence::authority_identity(std::string& pod_uid, std::string& boot_id, std::string& copy_id) {
	scoped l(&_mutex);
	pod_uid = _auth_pod_uid;
	boot_id = _auth_boot_id;
	copy_id = _auth_copy_id;
}

uint64_t write_fence::authority_begin_request() {
	uint32_t p;
	{
		scoped l(&_mutex);
		p = _auth_partition;
	}
	return authority_begin_request(p);
}

uint64_t write_fence::authority_begin_request(uint32_t partition) {
	scoped l(&_mutex);
	const uint64_t now = _auth_clock();		// the SEND point, on our own clock
	if (now == authority_clock_failed || _auth_registered.count(partition) == 0) {
		return 0;		// nonce 0 is never pending: no request can be granted
	}
	part_state& ps = _auth_parts[partition];
	const uint64_t nonce = _auth_next_nonce++;
	if (ps.pending.size() >= authority_max_pending) {
		ps.pending.erase(ps.pending.begin());
	}
	ps.pending[nonce] = now;
	return nonce;
}

bool write_fence::authority_apply_grant(const authority_grant& g, std::string& why) {
	// a change of authority (other term / generation than the one held)
	// drains the writes in flight first; a renewal of the same authority
	// takes no exclusive lock
	bool drain = false;
	for (;;) {
		{
			exclusive x(&_apply_rw, drain);
			scoped l(&_mutex);
			std::map<uint32_t, part_state>::iterator it = _auth_parts.find(g.partition);
			const bool change = it == _auth_parts.end() || !it->second.have
				|| !(g.term == it->second.term && g.generation == it->second.gen);
			if (!change || drain) {
				return _apply_grant_locked(g, why);
			}
		}
		drain = true;
	}
}

bool write_fence::_apply_grant_locked(const authority_grant& g, std::string& why) {
	if (!_auth_enabled) {
		why = "authority engine off";
		return false;
	}
	if (!_auth_identity_set || _auth_registered.count(g.partition) == 0 || g.pod_uid != _auth_pod_uid
			|| g.boot_id != _auth_boot_id || g.copy_id != _auth_copy_id) {
		why = "grant is bound to another identity";
		return false;
	}
	part_state& ps = _auth_parts[g.partition];
	std::map<uint64_t, uint64_t>::iterator it = ps.pending.find(g.nonce);
	if (it == ps.pending.end() || g.nonce <= ps.last_nonce) {
		why = "unknown, old or duplicate request nonce";
		return false;
	}
	if (ps.revoked && (g.term < ps.revoked_term
			|| (g.term == ps.revoked_term && g.generation <= ps.revoked_gen))) {
		why = "revoked";
		return false;
	}
	if ((ps.have && (g.term < ps.term || (g.term == ps.term && g.generation < ps.gen)))
			|| (ps.floor_set && (g.term < ps.floor_term || (g.term == ps.floor_term && g.generation < ps.floor_gen)))) {
		why = "older term or generation";
		return false;
	}
	const bool same = ps.have && g.term == ps.term && g.generation == ps.gen;
	if (same && g.solo != ps.solo) {
		why = "membership mode differs within one generation";
		return false;
	}
	uint64_t deadline = 0;
	if (!g.solo) {
		if (g.ttl_ns == 0) {
			why = "ttl must be positive";
			return false;
		}
		// from the REQUEST SEND point; the receive time never enters
		deadline = it->second + g.ttl_ns;
		if (deadline < it->second || _auth_clock() >= deadline) {
			why = "expired before it arrived";
			return false;
		}
		if (same && deadline < ps.deadline) {
			deadline = ps.deadline;		// a renewal never shortens
		}
	}
	ps.pending.erase(ps.pending.begin(), ps.pending.upper_bound(g.nonce));
	ps.last_nonce = g.nonce;
	ps.have = true;
	ps.term = g.term;
	ps.gen = g.generation;
	ps.solo = g.solo;
	ps.deadline = deadline;
	if (!same) {
		ps.serial++;		// a renewal of the same authority keeps it
		// this node is the master now: replica entries admitted before are void
		ps.floor_serial++;
	}
	if (!ps.floor_set || g.term > ps.floor_term || (g.term == ps.floor_term && g.generation > ps.floor_gen)) {
		ps.floor_set = true;
		ps.floor_term = g.term;
		ps.floor_gen = g.generation;
	}
	return true;
}

bool write_fence::authority_revoke(uint32_t partition, uint64_t term, uint64_t generation, std::string& why) {
	exclusive x(&_apply_rw, true);
	scoped l(&_mutex);
	if (!_auth_identity_set || _auth_registered.count(partition) == 0) {
		why = "another partition";
		return false;
	}
	part_state& ps = _auth_parts[partition];
	if (!ps.revoked || term > ps.revoked_term
			|| (term == ps.revoked_term && generation > ps.revoked_gen)) {
		ps.revoked = true;
		ps.revoked_term = term;
		ps.revoked_gen = generation;
	}
	if (ps.have && (ps.term < ps.revoked_term
			|| (ps.term == ps.revoked_term && ps.gen <= ps.revoked_gen))) {
		_clear_grant_locked(ps);
	} else {
		// requests sent before the revoke are void either way
		ps.pending.clear();
	}
	return true;
}

void write_fence::authority_set_floor(uint32_t partition, uint64_t term, uint64_t generation) {
	exclusive x(&_apply_rw, true);
	scoped l(&_mutex);
	part_state& ps = _auth_parts[partition];
	if (ps.floor_set && (term < ps.floor_term || (term == ps.floor_term && generation <= ps.floor_gen))) {
		return;		// never lowers
	}
	ps.floor_set = true;
	ps.floor_term = term;
	ps.floor_gen = generation;
	ps.floor_serial++;
	// a newer authority exists: a held grant of an older one is void
	if (ps.have && (ps.term < term || (ps.term == term && ps.gen < generation))) {
		_clear_grant_locked(ps);
	}
}

bool write_fence::authority_floor(uint32_t partition, uint64_t& term, uint64_t& generation) {
	scoped l(&_mutex);
	std::map<uint32_t, part_state>::const_iterator it = _auth_parts.find(partition);
	if (it == _auth_parts.end() || !it->second.floor_set) {
		return false;
	}
	term = it->second.floor_term;
	generation = it->second.floor_gen;
	return true;
}

bool write_fence::authority_valid() {
	uint32_t p;
	{
		scoped l(&_mutex);
		p = _auth_partition;
	}
	return authority_valid(p);
}

std::string write_fence::authority_current_tag(uint32_t partition) {
	scoped l(&_mutex);
	std::map<uint32_t, part_state>::const_iterator it = _auth_parts.find(partition);
	if (!_auth_enabled || it == _auth_parts.end() || !_authority_valid_locked(it->second, _auth_clock())) {
		return std::string();
	}
	char buf[96];
	snprintf(buf, sizeof(buf), "%u:%llu:%llu", partition,
		static_cast<unsigned long long>(it->second.term), static_cast<unsigned long long>(it->second.gen));
	return buf;
}

bool write_fence::authority_valid(uint32_t partition) {
	scoped l(&_mutex);
	std::map<uint32_t, part_state>::const_iterator it = _auth_parts.find(partition);
	return _auth_enabled && it != _auth_parts.end() && _authority_valid_locked(it->second, _auth_clock());
}

uint64_t write_fence::authority_drain_waits() {
	return __sync_fetch_and_add(&drain_waits, 0);
}

uint64_t write_fence::authority_refused() {
	scoped l(&_mutex);
	return _auth_refused;
}

void write_fence::authority_set_gettime(int (*gettime)(clockid_t, struct timespec*)) {
	scoped l(&_mutex);
	gettime_fn = gettime ? gettime : clock_gettime;
}

void write_fence::authority_set_clock(uint64_t (*clock)()) {
	scoped l(&_mutex);
	_auth_clock = clock ? clock : default_boottime_ns;
}

void write_fence::set_clock(time_t (*clock)()) {
	scoped l(&_mutex);
	_clock = clock ? clock : default_clock;
}

void write_fence::set_admit_hook(void (*hook)()) {
	scoped l(&_mutex);
	_admit_hook = hook;
}

void write_fence::set_entry_hook(void (*hook)()) {
	scoped l(&_mutex);
	_entry_hook = hook;
}

void write_fence::reset_for_test() {
	scoped l(&_mutex);
	_armed = false;
	_token.clear();
	_expires = 0;
	_in_flight = 0;
	_refused = 0;
	_generation = 0;
	_clock = default_clock;
	_entry_hook = NULL;
	_admit_hook = NULL;
	_auth_enabled = false;
	_auth_identity_set = false;
	_auth_partition = 0;
	_auth_pod_uid.clear();
	_auth_boot_id.clear();
	_auth_copy_id.clear();
	_auth_next_nonce = 1;
	_auth_parts.clear();
	_auth_registered.clear();
	_auth_refused = 0;
	_auth_clock = default_boottime_ns;
	gettime_fn = clock_gettime;
}

}	// namespace flare
}	// namespace gree
