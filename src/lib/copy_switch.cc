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

int read_small_file(const string& path, string& out) {
	out.clear();
	FILE* f = ::fopen(path.c_str(), "r");
	if (f == NULL) {
		return -1;
	}
	char buf[4096];
	size_t n;
	while ((n = ::fread(buf, 1, sizeof(buf), f)) > 0) {
		out.append(buf, n);
		if (out.size() > 65536) break;
	}
	::fclose(f);
	while (!out.empty() && (out[out.size() - 1] == '\n' || out[out.size() - 1] == '\r')) {
		out.erase(out.size() - 1);
	}
	return 0;
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
	if (!dir_exists(dir)) {
		return "";
	}
	string id;
	if (read_small_file(dir + "/" + kCopyIdFile, id) < 0 || id.empty()) {
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
	if (read_small_file(data_dir + "/" + kIntentFile, text) < 0) {
		return 0;	// no intent: nothing to recover
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
	if (read_small_file(data_dir + "/" + kIntentFile, text) == 0) {
		log_err("copy switch: an intent is still present; staging copies are NOT removed", 0);
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
