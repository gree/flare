/**
 *	copy_switch_fs.h
 *
 *	Filesystem side of the copy switch (design §4). The pure recovery decision
 *	is in copy_switch.h.
 */
#ifndef	COPY_SWITCH_FS_H
#define	COPY_SWITCH_FS_H

#include <string>
#include <vector>
#include "copy_switch.h"

using namespace std;

namespace gree {
namespace flare {
namespace copy_fs {

static const char* const kCopyIdFile = "COPY_ID";
static const char* const kIntentFile = "switch.intent";
static const char* const kStagingPrefix = "staging-";
static const char* const kRetainedPrefix = "retained-";
// in retained-<attempt>: what replaced it (design §8)
static const char* const kRetainedRecordFile = "REPLACED_BY";

int fsync_dir(const string& dir);
// tmp file + fsync + rename + fsync(dir)
int write_file_durable(const string& dir, const string& name, const string& content);
// Present only when the whole file was read; NOT a distinction between
// "absent" and "unreadable" (returns -1 for both): use read_small_file_status
// wherever absence would be read as "nothing to do" or "healthy".
int read_small_file(const string& path, string& out);

// A small file as read (review 2026-10-08, P1): ABSENT only when it does not
// exist (ENOENT); ERROR for any other open failure (EACCES, EIO, ...), a read
// error part-way (ferror), or a file larger than the limit (never returned
// truncated). A decision that would treat absence as safe must stop on ERROR.
enum file_status {
	file_absent = 0,
	file_present = 1,
	file_error = 2,
};
static const size_t kSmallFileLimit = 65536;
file_status read_small_file_status(const string& path, string& out, string* error = NULL);
// Whether a path exists: absent only on ENOENT, error on any other failure.
file_status stat_path_status(const string& path, string* error = NULL);

// TEST SEAM (unit tests only; never set in production): a path ending with
// `suffix` fails as if open / stat returned `err` (e.g. EACCES, EIO), or —
// with `partial` — as a read error AFTER part of the content was read.
// Deterministic under root, where permission changes do not take effect.
void set_read_fault_for_test(const string& suffix, int err, bool partial = false);
void clear_read_faults_for_test();
bool dir_exists(const string& path);
bool same_device(const string& a, const string& b);
// "" = no such directory, "?" = directory without a readable COPY_ID
string read_copy_id(const string& dir);
string serialize_intent(const switch_intent& in);
bool parse_intent(const string& text, switch_intent& in);
int write_intent(const string& data_dir, const switch_intent& in);
int remove_intent(const string& data_dir);
// rename + fsync(data_dir)
int rename_durable(const string& data_dir, const string& from, const string& to);
int remove_tree_path(const string& path);

// At open, BEFORE the live DB is opened: resolve a switch intent from what
// exists on disk (design §4.2). 0 = nothing to do or resolved; -1 = stop
// (inconsistent: nothing touched; the caller refuses to open).
int recover(const string& data_dir, const string& live_name, string& report);
// After recover(): remove every staging copy (unfinished attempts). Refuses
// while an intent is present. Returns the number removed, -1 on refusal.
int cleanup_staging(const string& data_dir);
// Remove every entry of data_dir whose name starts with `prefix`. Returns the
// number removed.
int remove_prefixed(const string& data_dir, const string& prefix);

// Steps 1-3 of the switch (the caller has made the new copy durable, closed
// the live DB, and opens + checks the new live and removes the intent after).
int switch_dirs(const string& data_dir, const string& live_name, const switch_intent& in);

}	// namespace copy_fs
}	// namespace flare
}	// namespace gree

#endif	// COPY_SWITCH_FS_H
