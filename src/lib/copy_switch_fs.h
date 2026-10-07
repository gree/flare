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

int fsync_dir(const string& dir);
// tmp file + fsync + rename + fsync(dir)
int write_file_durable(const string& dir, const string& name, const string& content);
int read_small_file(const string& path, string& out);
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

// Steps 1-3 of the switch (the caller has made the new copy durable, closed
// the live DB, and opens + checks the new live and removes the intent after).
int switch_dirs(const string& data_dir, const string& live_name, const switch_intent& in);

}	// namespace copy_fs
}	// namespace flare
}	// namespace gree

#endif	// COPY_SWITCH_FS_H
