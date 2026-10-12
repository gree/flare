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
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

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
}
