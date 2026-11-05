/**
 *	wal_pin.cc
 *
 *	See wal_pin.h.
 */
#include "wal_pin.h"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <sys/time.h>
#include <unistd.h>

#include "logger.h"

namespace gree {
namespace flare {
namespace wal_pin {

const char* state_name(state s) {
	switch (s) {
	case state_absent: return "none";
	case state_valid: return "active";
	case state_expired: return "expired";
	case state_invalid: return "invalid";
	}
	return "invalid";
}

string serialize(const pin& p) {
	ostringstream o;
	o << "v1 " << p.hid << " " << p.seq << " " << p.deadline_ms << "\n";
	return o.str();
}

namespace {
bool hid_ok(const string& h) {
	if (h.empty() || h.size() > 128) {
		return false;
	}
	for (size_t i = 0; i < h.size(); i++) {
		const char c = h[i];
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
				|| c == '.' || c == '_' || c == ':' || c == '-')) {
			return false;
		}
	}
	return true;
}

bool u64_of(const string& s, uint64_t& v) {
	if (s.empty() || s.size() > 20) {
		return false;
	}
	for (size_t i = 0; i < s.size(); i++) {
		if (s[i] < '0' || s[i] > '9') {
			return false;
		}
	}
	errno = 0;
	char* end = NULL;
	const unsigned long long x = strtoull(s.c_str(), &end, 10);
	if (errno != 0 || end == NULL || *end != '\0') {
		return false;
	}
	v = (uint64_t)x;
	return true;
}
}	// anonymous namespace

bool parse(const string& text, pin& p, string& why) {
	// one line "v1 <hid> <seq> <deadline_ms>", the newline optional
	// (copy_fs::read_small_file_status strips trailing line ends)
	string line = text;
	if (!line.empty() && line[line.size() - 1] == '\n') {
		line.erase(line.size() - 1);
	}
	if (line.empty() || line.find('\n') != string::npos || line.find('\r') != string::npos) {
		why = "not exactly one line";
		return false;
	}
	istringstream in(line);
	string ver, hid, seq, deadline, extra;
	in >> ver >> hid >> seq >> deadline;
	if (in >> extra) {
		why = "extra fields";
		return false;
	}
	if (ver != "v1") {
		why = "unknown version [" + ver + "]";
		return false;
	}
	if (!hid_ok(hid)) {
		why = "invalid handover id";
		return false;
	}
	pin r;
	r.hid = hid;
	if (!u64_of(seq, r.seq)) {
		why = "invalid sequence";
		return false;
	}
	if (!u64_of(deadline, r.deadline_ms) || r.deadline_ms == 0) {
		why = "invalid deadline";
		return false;
	}
	p = r;
	return true;
}

state decide(copy_fs::file_status st, const string& content, uint64_t now_ms, uint64_t max_pin_ms,
		pin& out, string& why) {
	if (st == copy_fs::file_absent) {
		why = "";
		return state_absent;
	}
	if (st != copy_fs::file_present) {
		why = "the marker exists but could not be read";
		return state_invalid;
	}
	pin p;
	string pwhy;
	if (!parse(content, p, pwhy)) {
		why = "malformed marker: " + pwhy;
		return state_invalid;
	}
	out = p;
	if (now_ms == 0) {
		why = "the clock could not be read: the deadline cannot be judged";
		return state_invalid;
	}
	if (max_pin_ms > 0 && p.deadline_ms > now_ms && p.deadline_ms - now_ms > 2 * max_pin_ms) {
		why = "the deadline is further ahead than twice the pin limit: the clock or the marker is not believed";
		return state_invalid;
	}
	if (p.deadline_ms <= now_ms) {
		why = "the deadline has passed";
		return state_expired;
	}
	why = "";
	return state_valid;
}

state read(const string& data_dir, uint64_t now_ms, uint64_t max_pin_ms, pin& out, string& why) {
	string content, err;
	const copy_fs::file_status st = copy_fs::read_small_file_status(data_dir + "/" + kFile, content, &err);
	const state s = decide(st, content, now_ms, max_pin_ms, out, why);
	if (st == copy_fs::file_error && !err.empty()) {
		why += " (" + err + ")";
	}
	return s;
}

int write(const string& data_dir, const pin& p) {
	return copy_fs::write_file_durable(data_dir, kFile, serialize(p));
}

namespace {
int g_remove_fault = 0;
bool g_remove_fault_after_unlink = false;
}	// anonymous namespace

void set_remove_fault_for_test(int err, bool after_unlink) {
	g_remove_fault = err;
	g_remove_fault_after_unlink = after_unlink;
}

int remove(const string& data_dir) {
	const string path = data_dir + "/" + kFile;
	if (g_remove_fault != 0 && !g_remove_fault_after_unlink) {
		log_err("WAL_PIN: unlink [%s] failed: %s (injected)", path.c_str(), strerror(g_remove_fault));
		return -1;
	}
	if (::unlink(path.c_str()) != 0 && errno != ENOENT) {
		log_err("WAL_PIN: unlink [%s] failed: %s", path.c_str(), strerror(errno));
		return -1;
	}
	if (g_remove_fault != 0) {
		log_err("WAL_PIN: fsync of [%s] after the unlink failed: %s (injected)", data_dir.c_str(), strerror(g_remove_fault));
		return -1;
	}
	return copy_fs::fsync_dir(data_dir);
}

uint64_t now_ms() {
	struct timeval tv;
	if (gettimeofday(&tv, NULL) != 0) {
		return 0;
	}
	return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

}	// namespace wal_pin
}	// namespace flare
}	// namespace gree
