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

pthread_mutex_t	write_fence::_mutex = PTHREAD_MUTEX_INITIALIZER;
bool			write_fence::_armed = false;
std::string		write_fence::_token;
time_t			write_fence::_expires = 0;
uint64_t		write_fence::_in_flight = 0;
uint64_t		write_fence::_refused = 0;
uint64_t		write_fence::_generation = 0;
time_t			(*write_fence::_clock)() = default_clock;
void			(*write_fence::_entry_hook)() = NULL;

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
		this->_fenced = _active_locked(_clock());
		if (this->_fenced) {
			_refused++;
		} else {
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
}

}	// namespace flare
}	// namespace gree
