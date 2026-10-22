/**
 *	write_fence.cc
 *
 *	implementation of gree::flare::write_fence (see the header)
 */
#include "write_fence.h"

namespace gree {
namespace flare {

static time_t default_clock() {
	return time(NULL);
}

static uint64_t default_boottime_ns() {
	struct timespec ts;
	clock_gettime(CLOCK_BOOTTIME, &ts);
	return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL + static_cast<uint64_t>(ts.tv_nsec);
}

static const size_t authority_max_pending = 64;

pthread_mutex_t	write_fence::_mutex = PTHREAD_MUTEX_INITIALIZER;
bool			write_fence::_armed = false;
std::string		write_fence::_token;
time_t			write_fence::_expires = 0;
uint64_t		write_fence::_in_flight = 0;
uint64_t		write_fence::_refused = 0;
uint64_t		write_fence::_generation = 0;
time_t			(*write_fence::_clock)() = default_clock;
void			(*write_fence::_entry_hook)() = NULL;
bool			write_fence::_auth_enabled = false;
bool			write_fence::_auth_identity_set = false;
uint32_t		write_fence::_auth_partition = 0;
std::string		write_fence::_auth_pod_uid;
std::string		write_fence::_auth_boot_id;
std::string		write_fence::_auth_copy_id;
uint64_t		write_fence::_auth_next_nonce = 1;
uint64_t		write_fence::_auth_last_nonce = 0;
std::map<uint64_t, uint64_t>	write_fence::_auth_pending;
bool			write_fence::_auth_have = false;
uint64_t		write_fence::_auth_term = 0;
uint64_t		write_fence::_auth_gen = 0;
uint64_t		write_fence::_auth_deadline = 0;
bool			write_fence::_auth_solo = false;
uint64_t		write_fence::_auth_serial = 0;
bool			write_fence::_auth_revoked = false;
uint64_t		write_fence::_auth_revoked_term = 0;
uint64_t		write_fence::_auth_revoked_gen = 0;
uint64_t		write_fence::_auth_refused = 0;
uint64_t		(*write_fence::_auth_clock)() = default_boottime_ns;

namespace {
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
		this->_bound_serial = 0;
		this->_fenced = _active_locked(_clock());
		if (this->_fenced) {
			_refused++;
		} else if (_auth_enabled && !_authority_valid_locked(_auth_clock())) {
			// the same check path: a master without a valid grant refuses
			this->_fenced = true;
			this->_no_authority = true;
			_refused++;
			_auth_refused++;
		} else {
			if (_auth_enabled) {
				this->_bound = true;
				this->_bound_serial = _auth_serial;
			}
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
	scoped l(&_mutex);
	_in_flight--;
}

bool write_fence::entry::ack_ok() {
	if (this->_fenced) {
		return false;
	}
	scoped l(&_mutex);
	if (!this->_bound && !_auth_enabled) {
		return true;
	}
	if (this->_bound && _auth_enabled && _auth_have && _auth_serial == this->_bound_serial
			&& _authority_valid_locked(_auth_clock())) {
		return true;
	}
	_auth_refused++;
	return false;
}

bool write_fence::_authority_valid_locked(uint64_t now) {
	if (!_auth_have) {
		return false;
	}
	return _auth_solo || now < _auth_deadline;
}

static void authority_clear_grant_locked(bool& have, uint64_t& deadline, bool& solo, std::map<uint64_t, uint64_t>& pending) {
	have = false;
	deadline = 0;
	solo = false;
	pending.clear();
}

void write_fence::authority_set_enabled(bool on) {
	scoped l(&_mutex);
	_auth_enabled = on;
	authority_clear_grant_locked(_auth_have, _auth_deadline, _auth_solo, _auth_pending);
	_auth_serial++;
}

bool write_fence::authority_enabled() {
	scoped l(&_mutex);
	return _auth_enabled;
}

void write_fence::authority_set_identity(uint32_t partition, const std::string& pod_uid,
		const std::string& boot_id, const std::string& copy_id) {
	scoped l(&_mutex);
	_auth_identity_set = true;
	_auth_partition = partition;
	_auth_pod_uid = pod_uid;
	_auth_boot_id = boot_id;
	_auth_copy_id = copy_id;
	// a different identity never inherits a grant bound to the old one
	authority_clear_grant_locked(_auth_have, _auth_deadline, _auth_solo, _auth_pending);
	_auth_serial++;
}

uint64_t write_fence::authority_begin_request() {
	scoped l(&_mutex);
	const uint64_t now = _auth_clock();		// the SEND point, on our own clock
	const uint64_t nonce = _auth_next_nonce++;
	if (_auth_pending.size() >= authority_max_pending) {
		_auth_pending.erase(_auth_pending.begin());
	}
	_auth_pending[nonce] = now;
	return nonce;
}

bool write_fence::authority_apply_grant(const authority_grant& g, std::string& why) {
	scoped l(&_mutex);
	if (!_auth_enabled) {
		why = "authority engine off";
		return false;
	}
	if (!_auth_identity_set || g.partition != _auth_partition || g.pod_uid != _auth_pod_uid
			|| g.boot_id != _auth_boot_id || g.copy_id != _auth_copy_id) {
		why = "grant is bound to another identity";
		return false;
	}
	std::map<uint64_t, uint64_t>::iterator it = _auth_pending.find(g.nonce);
	if (it == _auth_pending.end() || g.nonce <= _auth_last_nonce) {
		why = "unknown, old or duplicate request nonce";
		return false;
	}
	if (_auth_revoked && (g.term < _auth_revoked_term
			|| (g.term == _auth_revoked_term && g.generation <= _auth_revoked_gen))) {
		why = "revoked";
		return false;
	}
	if (_auth_have && (g.term < _auth_term || (g.term == _auth_term && g.generation < _auth_gen))) {
		why = "older term or generation";
		return false;
	}
	const bool same = _auth_have && g.term == _auth_term && g.generation == _auth_gen;
	if (same && g.solo != _auth_solo) {
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
		if (same && deadline < _auth_deadline) {
			deadline = _auth_deadline;		// a renewal never shortens
		}
	}
	_auth_pending.erase(_auth_pending.begin(), _auth_pending.upper_bound(g.nonce));
	_auth_last_nonce = g.nonce;
	_auth_have = true;
	_auth_term = g.term;
	_auth_gen = g.generation;
	_auth_solo = g.solo;
	_auth_deadline = deadline;
	_auth_serial++;
	return true;
}

bool write_fence::authority_revoke(uint32_t partition, uint64_t term, uint64_t generation, std::string& why) {
	scoped l(&_mutex);
	if (!_auth_identity_set || partition != _auth_partition) {
		why = "another partition";
		return false;
	}
	if (!_auth_revoked || term > _auth_revoked_term
			|| (term == _auth_revoked_term && generation > _auth_revoked_gen)) {
		_auth_revoked = true;
		_auth_revoked_term = term;
		_auth_revoked_gen = generation;
	}
	if (_auth_have && (_auth_term < _auth_revoked_term
			|| (_auth_term == _auth_revoked_term && _auth_gen <= _auth_revoked_gen))) {
		authority_clear_grant_locked(_auth_have, _auth_deadline, _auth_solo, _auth_pending);
		_auth_serial++;
	} else {
		// requests sent before the revoke are void either way
		_auth_pending.clear();
	}
	return true;
}

bool write_fence::authority_valid() {
	scoped l(&_mutex);
	return _auth_enabled && _authority_valid_locked(_auth_clock());
}

uint64_t write_fence::authority_refused() {
	scoped l(&_mutex);
	return _auth_refused;
}

void write_fence::authority_set_clock(uint64_t (*clock)()) {
	scoped l(&_mutex);
	_auth_clock = clock ? clock : default_boottime_ns;
}

void write_fence::set_clock(time_t (*clock)()) {
	scoped l(&_mutex);
	_clock = clock ? clock : default_clock;
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
	_auth_enabled = false;
	_auth_identity_set = false;
	_auth_partition = 0;
	_auth_pod_uid.clear();
	_auth_boot_id.clear();
	_auth_copy_id.clear();
	_auth_next_nonce = 1;
	_auth_last_nonce = 0;
	_auth_pending.clear();
	_auth_have = false;
	_auth_term = _auth_gen = _auth_deadline = 0;
	_auth_solo = false;
	_auth_serial = 0;
	_auth_revoked = false;
	_auth_revoked_term = _auth_revoked_gen = 0;
	_auth_refused = 0;
	_auth_clock = default_boottime_ns;
}

}	// namespace flare
}	// namespace gree
