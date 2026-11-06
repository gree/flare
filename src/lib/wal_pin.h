/**
 *	wal_pin.h
 *
 *	WAL retention across an ordered handover (docs/design-handover-history-
 *	continuation.md, 5th/6th revision). The new master keeps every WAL file
 *	from S on until every prepared follower has caught up past S, a deadline
 *	passes, or free space falls below a floor.
 *
 *	The intent lives OUTSIDE the DB, in data_dir/WAL_PIN, so it is read
 *	before DB::Open: the cleanup RocksDB does while opening would otherwise
 *	run before an intent inside the DB could be read. A marker that exists
 *	but cannot be read or judged is never treated as absent (fail closed).
 */
#ifndef	WAL_PIN_H
#define	WAL_PIN_H

#include <stdint.h>
#include <string>

#include "copy_switch_fs.h"

using namespace std;

namespace gree {
namespace flare {
namespace wal_pin {

static const char* const kFile = "WAL_PIN";
// The WAL options of a pinned open: every obsolete WAL file is archived and
// kept (TTL 10 years, no size cap), and log files are never recycled (a
// recycled file overwrites what GetUpdatesSince must still read).
static const uint64_t kKeepAllTtlSeconds = 315360000ULL;
static const uint64_t kKeepAllSizeLimitMb = 0;

struct pin {
	string hid;
	uint64_t seq;
	uint64_t deadline_ms;	// wall clock (epoch ms), the effective (capped) one
	// the deadline the pin was requested with, before the cap (0 = unknown,
	// a marker written before this field): a retry of the same request
	// after a restart is recognised as the same pin
	uint64_t requested_deadline_ms;
	pin(): seq(0), deadline_ms(0), requested_deadline_ms(0) {}
};

enum state {
	state_absent = 0,	// no marker
	state_valid,		// a readable marker whose deadline has not passed
	state_expired,		// a readable marker whose deadline has passed
	state_invalid,		// a marker that exists but cannot be read or judged
};

const char* state_name(state s);

string serialize(const pin& p);
bool parse(const string& text, pin& p, string& why);

/**
 *	Decide from what was read. `now_ms` 0 = the clock could not be read.
 *	`max_pin_ms` is the configured pin limit: a deadline further ahead than
 *	twice that is not believed (the clock went back, or the marker is wrong)
 *	and the marker is invalid, not valid for an unknown time.
 */
state decide(copy_fs::file_status st, const string& content, uint64_t now_ms, uint64_t max_pin_ms,
		pin& out, string& why);

// The marker as it is on disk now (read + decide).
state read(const string& data_dir, uint64_t now_ms, uint64_t max_pin_ms, pin& out, string& why);
// tmp file + fsync + rename + fsync(dir)
int write(const string& data_dir, const pin& p);
// unlink + fsync(dir); 0 when it is gone (also when it was absent)
int remove(const string& data_dir);
// TEST SEAM (unit tests only): remove() fails with `err` at the unlink
// (`after_unlink` false) or at the directory fsync after it (true); 0 clears
void set_remove_fault_for_test(int err, bool after_unlink = false);

uint64_t now_ms();

}	// namespace wal_pin
}	// namespace flare
}	// namespace gree

#endif	// WAL_PIN_H
