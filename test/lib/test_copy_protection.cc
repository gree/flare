/**
 *	test_copy_protection.cc
 *
 *	R3-D: the protection rule evaluated right before a replica's copy is
 *	destroyed or replaced (copy_protection.h). Mirrors the operator's
 *	repairSourceVerdict, evaluated at the destructive moment.
 */
#include <cppcutter.h>
#include <copy_protection.h>
#include <app.h>
#include <handler_reconstruction.h>
#include <stats.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <vector>

using namespace std;
using namespace gree::flare;

namespace test_copy_protection {
	copy_identity replica(uint64_t items, const string& lineage, const string& epoch,
			const string& from_lineage = "", const string& from_epoch = "") {
		copy_identity c;
		c.known = true;
		c.items = items;
		c.lineage = lineage;
		c.epoch = epoch;
		c.rebuilt_from_lineage = from_lineage;
		c.rebuilt_from_epoch = from_epoch;
		return c;
	}

	copy_identity source(uint64_t items, const string& lineage, const string& epoch, const string& reason) {
		copy_identity c;
		c.known = true;
		c.items = items;
		c.lineage = lineage;
		c.epoch = epoch;
		c.epoch_reason = reason;
		return c;
	}

	void test_empty_local_copy_has_nothing_to_protect() {
		string why;
		cut_assert_equal_int(gate_allow_nothing_to_protect,
			decide_copy_gate(replica(0, "L", "e1"), source(0, "OTHER", "e9", "promotion"), why));
	}

	void test_source_with_keys_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow, decide_copy_gate(replica(400, "L", "e1"), source(3, "L", "e9", "promotion"), why));
	}

	// test 9 / H1: the source was promoted (new epoch) and is EMPTY; the
	// replica's copy and evidence belong to the earlier history
	void test_dangerous_empty_source_keeps_the_copy() {
		string why;
		cut_assert_equal_int(gate_refuse_unsafe,
			decide_copy_gate(replica(400, "L", "e1", "L", "e1"), source(0, "L", "e2", "promotion"), why));
	}

	// test 2: the replica was rebuilt by a full dump from exactly this
	// history; the master was deleted to empty afterwards
	void test_legitimate_empty_source_by_rebuild_evidence_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow,
			decide_copy_gate(replica(400, "L", "own", "L", "e2"), source(0, "L", "e2", "promotion"), why));
	}

	void test_empty_source_in_the_same_history_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow, decide_copy_gate(replica(400, "L", "e2"), source(0, "L", "e2", "promotion"), why));
	}

	void test_empty_source_after_a_bulk_rewrite_proceeds() {
		string why;
		cut_assert_equal_int(gate_allow, decide_copy_gate(replica(400, "L", "e1"), source(0, "L", "e3", "bulk"), why));
	}

	void test_empty_source_of_another_lineage_keeps_the_copy() {
		string why;
		cut_assert_equal_int(gate_refuse_unsafe, decide_copy_gate(replica(400, "L", "e1"), source(0, "OTHER", "e1", "bulk"), why));
		cut_assert_equal_int(gate_refuse_unsafe, decide_copy_gate(replica(400, "", "e1"), source(0, "L", "e1", "bulk"), why));
	}

	// Unknown at the boundary: keep the copy, wait
	void test_unknown_source_keeps_the_copy() {
		string why;
		copy_identity unknown;
		cut_assert_equal_int(gate_refuse_unknown, decide_copy_gate(replica(400, "L", "e1"), unknown, why));
	}

	// an unreadable (corrupt) local copy is not an empty one
	void test_unreadable_local_copy_is_protected() {
		string why;
		copy_identity local;
		local.known = false;
		local.items = 0;
		cut_assert_equal_int(gate_refuse_unsafe, decide_copy_gate(local, source(0, "L", "e2", "promotion"), why));
		copy_identity unknown;
		cut_assert_equal_int(gate_refuse_unknown, decide_copy_gate(local, unknown, why));
	}

	void test_allow_and_names() {
		cut_assert_true(copy_gate_allows(gate_allow));
		cut_assert_true(copy_gate_allows(gate_allow_nothing_to_protect));
		cut_assert_false(copy_gate_allows(gate_refuse_unknown));
		cut_assert_false(copy_gate_allows(gate_refuse_unsafe));
	}

	// T24 (round 8): the identity/size probe makes a FRESH connection, so a
	// fresh lookup, when it got no complete reply — one connection resolves
	// once and its connect retries reuse that address, so a single stale
	// answer used to fail the probe (and park the staged rebuild). Here the
	// source starts listening only after the probe's first attempt failed.
	struct late_source {
		int port;
		int delay_ms;
		int accepted;
	};

	void* late_source_run(void* arg) {
		late_source* ls = static_cast<late_source*>(arg);
		usleep(ls->delay_ms * 1000);
		int fd = socket(AF_INET, SOCK_STREAM, 0);
		int one = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		struct sockaddr_in a;
		memset(&a, 0, sizeof(a));
		a.sin_family = AF_INET;
		a.sin_port = htons(ls->port);
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		if (::bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0 || listen(fd, 4) < 0) {
			close(fd);
			return NULL;
		}
		int c = accept(fd, NULL, NULL);
		if (c >= 0) {
			ls->accepted++;
			char buf[64];
			ssize_t n = read(c, buf, sizeof(buf));
			(void)n;
			const char* reply = "STAT curr_items 5\r\nSTAT rocksdb_master_id L\r\nSTAT rocksdb_source_epoch e1\r\nSTAT rocksdb_copy_bytes 100\r\nEND\r\n";
			ssize_t w = write(c, reply, strlen(reply));
			(void)w;
			close(c);
		}
		close(fd);
		return NULL;
	}

	uint64_t now_ms() {
		struct timeval tv;
		gettimeofday(&tv, NULL);
		return (uint64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
	}

	void test_probe_reaches_a_source_that_answers_only_on_a_later_attempt() {
		stats_object = new stats();
		const int saved_attempts = handler_reconstruction::probe_attempts;
		const int saved_wait = handler_reconstruction::probe_retry_wait_ms;
		handler_reconstruction::probe_attempts = 3;
		handler_reconstruction::probe_retry_wait_ms = 300;
		late_source ls;
		ls.port = 20000 + rand() % 20000;
		// attempt 1 fails by ~0.5 s (refused, one connect retry), attempt 2
		// at ~0.8 s fails by ~1.3 s, attempt 3 at ~1.9 s finds the listener
		ls.delay_ms = 1600;
		ls.accepted = 0;
		pthread_t th;
		pthread_create(&th, NULL, late_source_run, &ls);
		copy_identity out;
		const uint64_t t0 = now_ms();
		handler_reconstruction::probe_source_identity("localhost", ls.port, out);
		const uint64_t took = now_ms() - t0;
		pthread_join(th, NULL);
		handler_reconstruction::probe_attempts = saved_attempts;
		handler_reconstruction::probe_retry_wait_ms = saved_wait;
		delete stats_object;
		stats_object = NULL;
		cut_notify("probe took %llu ms, accepted %d", (unsigned long long)took, ls.accepted);
		cut_assert_equal_boolean(true, out.answered);
		cut_assert_equal_boolean(true, out.known);
		cut_assert_equal_int(5, (int)out.items);
		cut_assert_equal_string("L", out.lineage.c_str());
		cut_assert_equal_string("e1", out.epoch.c_str());
		cut_assert_equal_boolean(true, out.size_known);
		cut_assert_equal_int(100, (int)out.copy_bytes);
	}

	// nothing ever answers: Unknown and NOT answered (the staged rebuild
	// then fails the attempt for a retry instead of parking), in bounded time
	void test_probe_of_an_unreachable_source_is_unanswered_and_bounded() {
		stats_object = new stats();
		const int saved_attempts = handler_reconstruction::probe_attempts;
		const int saved_wait = handler_reconstruction::probe_retry_wait_ms;
		handler_reconstruction::probe_attempts = 3;
		handler_reconstruction::probe_retry_wait_ms = 100;
		copy_identity out;
		const uint64_t t0 = now_ms();
		handler_reconstruction::probe_source_identity("localhost", 1 + rand() % 1000 + 40000, out);
		const uint64_t took = now_ms() - t0;
		handler_reconstruction::probe_attempts = saved_attempts;
		handler_reconstruction::probe_retry_wait_ms = saved_wait;
		delete stats_object;
		stats_object = NULL;
		cut_notify("unreachable probe took %llu ms", (unsigned long long)took);
		cut_assert_equal_boolean(false, out.answered);
		cut_assert_equal_boolean(false, out.known);
		cut_assert_equal_boolean(false, out.size_known);
		cut_assert(took < 10000, cut_message("an unreachable probe took %llu ms", (unsigned long long)took));
	}

	// review of 492aff7: a slave takes a catch-up target only with proof,
	// read from the source, that the source forwards its writes here (its
	// map names this node a slave of the partition and itself the master,
	// at a version not older than this node's). Anything else is no proof.
	handler_reconstruction::source_map_view view(bool version_found, uint64_t version,
			const string& my_role, const string& my_state, const string& my_part,
			const string& src_role = "master", const string& src_part = "0") {
		handler_reconstruction::source_map_view v;
		v.version_found = version_found;
		v.version = version;
		if (!my_role.empty()) {
			v.role["me:12121"] = my_role;
			v.state["me:12121"] = my_state;
			v.partition["me:12121"] = my_part;
		}
		if (!src_role.empty()) {
			v.role["src:12121"] = src_role;
			v.state["src:12121"] = "active";
			v.partition["src:12121"] = src_part;
		}
		return v;
	}

	bool forwards(const handler_reconstruction::source_map_view& v, uint64_t mine = 7) {
		string why;
		const bool r = handler_reconstruction::source_forwards_here(v, "me:12121", "src:12121", 0, mine, why);
		cut_notify("%s -> %s", why.c_str(), r ? "proof" : "no proof");
		return r;
	}

	void test_source_forwarding_proof_rules() {
		// the proof: the source's map at this node's version names it a slave
		cut_assert_equal_boolean(true, forwards(view(true, 7, "slave", "prepare", "0")));
		cut_assert_equal_boolean(true, forwards(view(true, 9, "slave", "active", "0")));
		// an older source (no node_map_version reported) is NOT proof: fail closed
		cut_assert_equal_boolean(false, forwards(view(false, 0, "slave", "prepare", "0")));
		// the source has not applied this node's map yet
		cut_assert_equal_boolean(false, forwards(view(true, 6, "slave", "prepare", "0")));
		// a version at least this node's, but its map does not name this node
		// a slave of the partition (absent, a proxy, another partition, down):
		// the version alone proves nothing
		cut_assert_equal_boolean(false, forwards(view(true, 7, "", "", "")));
		cut_assert_equal_boolean(false, forwards(view(true, 7, "proxy", "active", "-1")));
		cut_assert_equal_boolean(false, forwards(view(true, 7, "slave", "prepare", "1")));
		cut_assert_equal_boolean(false, forwards(view(true, 7, "slave", "down", "0")));
		// the source is not the partition's master in its own map
		cut_assert_equal_boolean(false, forwards(view(true, 7, "slave", "prepare", "0", "proxy", "-1")));
		cut_assert_equal_boolean(false, forwards(view(true, 7, "slave", "prepare", "0", "", "")));
		// a newer local map raises the bar (the caller re-reads it every round)
		cut_assert_equal_boolean(false, forwards(view(true, 7, "slave", "prepare", "0"), 8));
	}

	// the probe reads `stats` and `stats nodes` on one connection, in the
	// format flared sends them
	struct map_source {
		int port;
		bool with_version;
		int ready;
	};

	void* map_source_run(void* arg) {
		map_source* ms = static_cast<map_source*>(arg);
		int fd = socket(AF_INET, SOCK_STREAM, 0);
		int one = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		struct sockaddr_in a;
		memset(&a, 0, sizeof(a));
		a.sin_family = AF_INET;
		a.sin_port = htons(ms->port);
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		if (::bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0 || listen(fd, 4) < 0) {
			close(fd);
			ms->ready = -1;
			return NULL;
		}
		ms->ready = 1;
		int c = accept(fd, NULL, NULL);
		if (c >= 0) {
			const char* replies[2];
			replies[0] = ms->with_version
				? "STAT pid 1\r\nSTAT node_map_version 7\r\nSTAT curr_items 3\r\nEND\r\n"
				: "STAT pid 1\r\nSTAT curr_items 3\r\nEND\r\n";
			replies[1] = "STAT src:12121:role master\r\nSTAT src:12121:state active\r\nSTAT src:12121:partition 0\r\n"
				"STAT src:12121:balance 100\r\nSTAT src:12121:thread_type 16\r\n"
				"STAT me:12121:role slave\r\nSTAT me:12121:state prepare\r\nSTAT me:12121:partition 0\r\n"
				"STAT me:12121:balance 0\r\nSTAT me:12121:thread_type 17\r\nEND\r\n";
			for (int r = 0; r < 2; r++) {
				// one request line each ("stats", "stats nodes")
				string line;
				char ch;
				while (read(c, &ch, 1) == 1) {
					line += ch;
					if (ch == '\n') {
						break;
					}
				}
				ssize_t w = write(c, replies[r], strlen(replies[r]));
				(void)w;
			}
			close(c);
		}
		close(fd);
		return NULL;
	}

	void probe_map_source(bool with_version, handler_reconstruction::source_map_view& v, int& rc) {
		map_source ms;
		ms.port = 20000 + rand() % 20000;
		ms.with_version = with_version;
		ms.ready = 0;
		pthread_t th;
		pthread_create(&th, NULL, map_source_run, &ms);
		for (int i = 0; i < 100 && ms.ready == 0; i++) {
			usleep(10 * 1000);
		}
		rc = handler_reconstruction::probe_source_map("localhost", ms.port, v);
		pthread_join(th, NULL);
	}

	void test_probe_reads_the_sources_version_and_map() {
		stats_object = new stats();
		handler_reconstruction::source_map_view v;
		int rc = 0;
		probe_map_source(true, v, rc);
		delete stats_object;
		stats_object = NULL;
		cut_assert_equal_int(1, rc);
		cut_assert_equal_boolean(true, v.version_found);
		cut_assert_equal_int(7, (int)v.version);
		cut_assert_equal_string("slave", v.role["me:12121"].c_str());
		cut_assert_equal_string("prepare", v.state["me:12121"].c_str());
		cut_assert_equal_string("0", v.partition["me:12121"].c_str());
		cut_assert_equal_string("master", v.role["src:12121"].c_str());
		cut_assert_equal_boolean(true, forwards(v));
	}

	// an older source that answers `stats` without node_map_version: the
	// reply is complete, but it is no proof — no catch-up target is taken
	void test_an_older_source_without_a_map_version_is_no_proof() {
		stats_object = new stats();
		handler_reconstruction::source_map_view v;
		int rc = 0;
		probe_map_source(false, v, rc);
		delete stats_object;
		stats_object = NULL;
		cut_assert_equal_int(1, rc);
		cut_assert_equal_boolean(false, v.version_found);
		cut_assert_equal_boolean(false, forwards(v));
	}

	// review of 163f674: the whole wait has ONE deadline; a source that
	// accepts and never answers must not stretch it (each probe gets only
	// the time left)
	struct silent_source {
		int port;
		volatile int ready;
		volatile int stop;
		int accepted;
	};

	void* silent_source_run(void* arg) {
		silent_source* ss = static_cast<silent_source*>(arg);
		int fd = socket(AF_INET, SOCK_STREAM, 0);
		int one = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		struct sockaddr_in a;
		memset(&a, 0, sizeof(a));
		a.sin_family = AF_INET;
		a.sin_port = htons(ss->port);
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		if (::bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0 || listen(fd, 16) < 0) {
			close(fd);
			ss->ready = -1;
			return NULL;
		}
		ss->ready = 1;
		vector<int> held;
		while (!ss->stop) {
			fd_set rf;
			FD_ZERO(&rf);
			FD_SET(fd, &rf);
			struct timeval tv = {0, 50 * 1000};
			if (select(fd + 1, &rf, NULL, NULL, &tv) > 0) {
				int c = accept(fd, NULL, NULL);
				if (c >= 0) {
					ss->accepted++;
					held.push_back(c);		// read nothing, answer nothing
				}
			}
		}
		for (size_t i = 0; i < held.size(); i++) {
			close(held[i]);
		}
		close(fd);
		return NULL;
	}

	void test_the_proof_wait_ends_within_its_budget_on_a_silent_source() {
		stats_object = new stats();
		silent_source ss;
		ss.port = 20000 + rand() % 20000;
		ss.ready = 0;
		ss.stop = 0;
		ss.accepted = 0;
		pthread_t th;
		pthread_create(&th, NULL, silent_source_run, &ss);
		for (int i = 0; i < 100 && ss.ready == 0; i++) {
			usleep(10 * 1000);
		}
		string last;
		const uint64_t t0 = now_ms();
		const bool ok = handler_reconstruction::wait_source_forwards_here("localhost", ss.port, "me:12121", "src:12121",
			0, NULL, 1500, shared_thread(), last);
		const uint64_t took = now_ms() - t0;
		ss.stop = 1;
		pthread_join(th, NULL);
		delete stats_object;
		stats_object = NULL;
		cut_notify("silent source: %s after %llu ms (%d connection(s) accepted; last: %s)", ok ? "proof" : "no proof",
			(unsigned long long)took, ss.accepted, last.c_str());
		cut_assert_equal_boolean(false, ok);
		cut_assert(ss.accepted >= 1, cut_message("the source was never reached"));
		cut_assert(took >= 1400 && took <= 1800, cut_message("a 1500 ms wait took %llu ms", (unsigned long long)took));
	}

	void test_the_proof_wait_returns_on_a_source_that_proves_it() {
		stats_object = new stats();
		map_source ms;
		ms.port = 20000 + rand() % 20000;
		ms.with_version = true;
		ms.ready = 0;
		pthread_t th;
		pthread_create(&th, NULL, map_source_run, &ms);
		for (int i = 0; i < 100 && ms.ready == 0; i++) {
			usleep(10 * 1000);
		}
		string last;
		const uint64_t t0 = now_ms();
		const bool ok = handler_reconstruction::wait_source_forwards_here("localhost", ms.port, "me:12121", "src:12121",
			0, NULL, 5000, shared_thread(), last);
		const uint64_t took = now_ms() - t0;
		pthread_join(th, NULL);
		delete stats_object;
		stats_object = NULL;
		cut_notify("proving source: %s after %llu ms (%s)", ok ? "proof" : "no proof", (unsigned long long)took, last.c_str());
		cut_assert_equal_boolean(true, ok);
		cut_assert(took < 2000, cut_message("took %llu ms", (unsigned long long)took));
	}
}
