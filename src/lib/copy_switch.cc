/**
 *	copy_switch.cc
 *
 *	Filesystem side of the copy switch (copy_switch.h, design §4): durable
 *	small files, the intent, recovery at open, and the switch itself.
 */
#include "copy_switch_fs.h"
#include "app.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sstream>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace gree {
namespace flare {
namespace copy_fs {

int fsync_dir(const string& dir) {
	int fd = ::open(dir.c_str(), O_RDONLY);
	if (fd < 0) {
		log_err("copy switch: cannot open dir [%s] for fsync: %s", dir.c_str(), strerror(errno));
		return -1;
	}
	int r = ::fsync(fd);
	const int e = errno;
	::close(fd);
	if (r != 0) {
		log_err("copy switch: fsync of dir [%s] failed: %s", dir.c_str(), strerror(e));
		return -1;
	}
	return 0;
}

int write_file_durable(const string& dir, const string& name, const string& content) {
	const string tmp = dir + "/." + name + ".tmp";
	const string dst = dir + "/" + name;
	int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		log_err("copy switch: cannot create [%s]: %s", tmp.c_str(), strerror(errno));
		return -1;
	}
	size_t off = 0;
	while (off < content.size()) {
		ssize_t w = ::write(fd, content.data() + off, content.size() - off);
		if (w < 0) {
			if (errno == EINTR) continue;
			log_err("copy switch: write to [%s] failed: %s", tmp.c_str(), strerror(errno));
			::close(fd);
			return -1;
		}
		off += (size_t)w;
	}
	if (::fsync(fd) != 0) {
		log_err("copy switch: fsync of [%s] failed: %s", tmp.c_str(), strerror(errno));
		::close(fd);
		return -1;
	}
	::close(fd);
	if (::rename(tmp.c_str(), dst.c_str()) != 0) {
		log_err("copy switch: rename [%s] -> [%s] failed: %s", tmp.c_str(), dst.c_str(), strerror(errno));
		return -1;
	}
	return fsync_dir(dir);
}

namespace {
struct read_fault {
	string suffix;
	int err;
	bool partial;
};
vector<read_fault> g_read_faults;

bool ends_with(const string& s, const string& suffix) {
	return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

const read_fault* fault_for(const string& path) {
	for (size_t i = 0; i < g_read_faults.size(); i++) {
		if (ends_with(path, g_read_faults[i].suffix)) {
			return &g_read_faults[i];
		}
	}
	return NULL;
}
}

void set_read_fault_for_test(const string& suffix, int err, bool partial) {
	read_fault f;
	f.suffix = suffix;
	f.err = err;
	f.partial = partial;
	g_read_faults.push_back(f);
}

void clear_read_faults_for_test() {
	g_read_faults.clear();
}

file_status read_small_file_status(const string& path, string& out, string* error) {
	out.clear();
	const read_fault* fault = fault_for(path);
	if (fault != NULL && !fault->partial) {
		if (error != NULL) *error = string("open: ") + strerror(fault->err) + " (injected)";
		return fault->err == ENOENT ? file_absent : file_error;
	}
	FILE* f = ::fopen(path.c_str(), "r");
	if (f == NULL) {
		const int e = errno;
		if (e == ENOENT) {
			return file_absent;
		}
		if (error != NULL) *error = string("open: ") + strerror(e);
		return file_error;
	}
	char buf[4096];
	size_t n;
	bool too_large = false;
	while ((n = ::fread(buf, 1, sizeof(buf), f)) > 0) {
		out.append(buf, n);
		if (out.size() > kSmallFileLimit) {
			too_large = true;
			break;
		}
	}
	const bool read_error = ::ferror(f) != 0 || (fault != NULL && fault->partial);
	const int e = errno;
	::fclose(f);
	if (too_large || read_error) {
		if (error != NULL) {
			*error = too_large ? "larger than the small-file limit (not returned truncated)"
				: (fault != NULL ? string("read: ") + strerror(fault->err) + " part-way (injected)" : string("read: ") + strerror(e) + " part-way");
		}
		out.clear();
		return file_error;
	}
	while (!out.empty() && (out[out.size() - 1] == '\n' || out[out.size() - 1] == '\r')) {
		out.erase(out.size() - 1);
	}
	return file_present;
}

int read_small_file(const string& path, string& out) {
	return read_small_file_status(path, out) == file_present ? 0 : -1;
}

file_status stat_path_status(const string& path, string* error) {
	const read_fault* fault = fault_for(path);
	if (fault != NULL) {
		if (error != NULL) *error = string("stat: ") + strerror(fault->err) + " (injected)";
		return fault->err == ENOENT ? file_absent : file_error;
	}
	struct stat st;
	if (::stat(path.c_str(), &st) == 0) {
		return file_present;
	}
	const int e = errno;
	if (e == ENOENT) {
		return file_absent;
	}
	if (error != NULL) *error = string("stat: ") + strerror(e);
	return file_error;
}

bool dir_exists(const string& path) {
	struct stat st;
	return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool same_device(const string& a, const string& b) {
	struct stat sa, sb;
	if (::stat(a.c_str(), &sa) != 0 || ::stat(b.c_str(), &sb) != 0) {
		return false;
	}
	return sa.st_dev == sb.st_dev;
}

string read_copy_id(const string& dir) {
	// "" only when the directory is confirmed absent; any other failure to
	// look is "?" (unknown), never "no such copy" (review P1)
	const file_status ds = stat_path_status(dir);
	if (ds == file_absent) {
		return "";
	}
	if (ds == file_error || !dir_exists(dir)) {
		return "?";
	}
	string id;
	if (read_small_file_status(dir + "/" + kCopyIdFile, id) != file_present || id.empty()) {
		return "?";
	}
	return id;
}

string serialize_intent(const switch_intent& in) {
	ostringstream s;
	s << "attempt=" << in.attempt << "\n" << "old=" << in.old_id << "\n"
		<< "new=" << in.new_id << "\n" << "phase=" << in.phase << "\n";
	return s.str();
}

bool parse_intent(const string& text, switch_intent& in) {
	in = switch_intent();
	istringstream s(text);
	string line;
	while (std::getline(s, line)) {
		const size_t eq = line.find('=');
		if (eq == string::npos) continue;
		const string k = line.substr(0, eq);
		const string v = line.substr(eq + 1);
		if (k == "attempt") in.attempt = v;
		else if (k == "old") in.old_id = v;
		else if (k == "new") in.new_id = v;
		else if (k == "phase") in.phase = v;
	}
	return !in.attempt.empty() && !in.old_id.empty() && !in.new_id.empty();
}

int write_intent(const string& data_dir, const switch_intent& in) {
	return write_file_durable(data_dir, kIntentFile, serialize_intent(in));
}

int remove_intent(const string& data_dir) {
	const string p = data_dir + "/" + kIntentFile;
	if (::unlink(p.c_str()) != 0 && errno != ENOENT) {
		log_err("copy switch: cannot remove the intent [%s]: %s", p.c_str(), strerror(errno));
		return -1;
	}
	return fsync_dir(data_dir);
}

int rename_durable(const string& data_dir, const string& from, const string& to) {
	if (::rename(from.c_str(), to.c_str()) != 0) {
		log_err("copy switch: rename [%s] -> [%s] failed: %s", from.c_str(), to.c_str(), strerror(errno));
		return -1;
	}
	return fsync_dir(data_dir);
}

int recover(const string& data_dir, const string& live_name, string& report) {
	report.clear();
	string text;
	string err;
	switch (read_small_file_status(data_dir + "/" + kIntentFile, text, &err)) {
	case file_absent:
		return 0;	// no intent: nothing to recover
	case file_error:
		// an intent that cannot be read is NOT "no intent" (review P1): the
		// live copy may already be retained and the new one still staged
		report = "the switch intent could not be read (" + err + "): STOP (nothing touched)";
		log_err("copy switch recovery: %s", report.c_str());
		return -1;
	default:
		break;
	}
	switch_intent in;
	if (!parse_intent(text, in)) {
		report = "the switch intent is unreadable [" + text + "]: STOP (nothing touched)";
		log_err("copy switch recovery: %s", report.c_str());
		return -1;
	}
	const string live = data_dir + "/" + live_name;
	const string retained = data_dir + "/" + kRetainedPrefix + in.attempt;
	const string staging = data_dir + "/" + kStagingPrefix + in.attempt;
	switch_observation o;
	o.live = read_copy_id(live);
	o.retained = read_copy_id(retained);
	o.staging = read_copy_id(staging);
	string why;
	const switch_recovery d = decide_switch_recovery(in, o, why);
	report = string(switch_recovery_name(d)) + ": " + why + " (attempt " + in.attempt + ", phase recorded " + in.phase + ")";
	switch (d) {
	case recovery_abort_attempt:
		log_warning("copy switch recovery: %s", report.c_str());
		return remove_intent(data_dir);
	case recovery_rollback:
		log_warning("copy switch recovery: %s", report.c_str());
		if (rename_durable(data_dir, retained, live) < 0) return -1;
		return remove_intent(data_dir);
	case recovery_roll_forward:
		// the new copy is live; the caller opens it and checks its COPY_ID
		log_warning("copy switch recovery: %s", report.c_str());
		return remove_intent(data_dir);
	default:
		log_err("copy switch recovery: %s", report.c_str());
		return -1;
	}
}

int cleanup_staging(const string& data_dir) {
	// Only after the intent was resolved (recover() returned 0 and removed it):
	// every staging copy left is an unfinished attempt.
	string text;
	string err;
	const file_status is = read_small_file_status(data_dir + "/" + kIntentFile, text, &err);
	if (is == file_present) {
		log_err("copy switch: an intent is still present; staging copies are NOT removed", 0);
		return -1;
	}
	if (is == file_error) {
		log_err("copy switch: the intent could not be read (%s); staging copies are NOT removed", err.c_str());
		return -1;
	}
	DIR* d = ::opendir(data_dir.c_str());
	if (d == NULL) {
		return 0;
	}
	struct dirent* e;
	int removed = 0;
	vector<string> victims;
	while ((e = ::readdir(d)) != NULL) {
		const string n = e->d_name;
		if (n.compare(0, strlen(kStagingPrefix), kStagingPrefix) == 0) {
			victims.push_back(data_dir + "/" + n);
		}
	}
	::closedir(d);
	for (vector<string>::iterator it = victims.begin(); it != victims.end(); it++) {
		if (remove_tree_path(*it) == 0) {
			removed++;
			log_notice("copy switch: removed the unfinished staging copy [%s]", it->c_str());
		}
	}
	if (removed > 0) {
		fsync_dir(data_dir);
	}
	return removed;
}

int remove_prefixed(const string& data_dir, const string& prefix) {
	DIR* d = ::opendir(data_dir.c_str());
	if (d == NULL) {
		return 0;
	}
	vector<string> victims;
	struct dirent* e;
	while ((e = ::readdir(d)) != NULL) {
		const string n = e->d_name;
		if (n.size() > prefix.size() && n.compare(0, prefix.size(), prefix) == 0) {
			victims.push_back(data_dir + "/" + n);
		}
	}
	::closedir(d);
	int removed = 0;
	for (vector<string>::iterator it = victims.begin(); it != victims.end(); it++) {
		if (remove_tree_path(*it) == 0) {
			removed++;
			log_notice("removed [%s] left by a previous process", it->c_str());
		}
	}
	if (removed > 0) {
		fsync_dir(data_dir);
	}
	return removed;
}

int remove_tree_path(const string& path) {
	struct stat st;
	if (::lstat(path.c_str(), &st) != 0) {
		return errno == ENOENT ? 0 : -1;
	}
	if (S_ISDIR(st.st_mode)) {
		DIR* d = ::opendir(path.c_str());
		if (d == NULL) return -1;
		struct dirent* e;
		vector<string> children;
		while ((e = ::readdir(d)) != NULL) {
			const string n = e->d_name;
			if (n == "." || n == "..") continue;
			children.push_back(path + "/" + n);
		}
		::closedir(d);
		for (vector<string>::iterator it = children.begin(); it != children.end(); it++) {
			if (remove_tree_path(*it) != 0) return -1;
		}
		return ::rmdir(path.c_str()) == 0 ? 0 : -1;
	}
	return ::unlink(path.c_str()) == 0 ? 0 : -1;
}

int switch_dirs(const string& data_dir, const string& live_name, const switch_intent& in) {
	const string live = data_dir + "/" + live_name;
	const string retained = data_dir + "/" + kRetainedPrefix + in.attempt;
	const string staging = data_dir + "/" + kStagingPrefix + in.attempt;
	if (!same_device(data_dir, staging) || !same_device(data_dir, live)) {
		log_err("copy switch: the copies are not on the data dir's filesystem; refusing to switch", 0);
		return -1;
	}
	if (read_copy_id(staging) != in.new_id || read_copy_id(live) != in.old_id) {
		log_err("copy switch: the copy ids on disk do not match the intent (live %s, staging %s); refusing to switch",
			read_copy_id(live).c_str(), read_copy_id(staging).c_str());
		return -1;
	}
	switch_intent prepared = in;
	prepared.phase = "prepared";
	if (write_intent(data_dir, prepared) < 0) return -1;
	if (rename_durable(data_dir, live, retained) < 0) return -1;
	switch_intent r = in;
	r.phase = "live_retained";
	write_intent(data_dir, r);		// diagnostic only: recovery does not rely on it
	if (rename_durable(data_dir, staging, live) < 0) return -1;
	r.phase = "new_live";
	write_intent(data_dir, r);
	return 0;
}

}	// namespace copy_fs
}	// namespace flare
}	// namespace gree
