/**
 *	test_handler_reconstruction.cc
 *
 *	The reconstruction retry loop (handler_reconstruction::run) of a slave
 *	whose own node is a PROXY in its current map: it is abandoned (-1, stats
 *	"aborted") at the top of the attempt, before any contact with the source;
 *	a node that is still a slave of the partition keeps its attempts.
 */
#include <cppcutter.h>
#include <app.h>
#include <stats.h>
#include <thread_pool.h>
#include <handler_reconstruction.h>
#include "mock_cluster.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

using namespace std;
using namespace gree::flare;

namespace test_handler_reconstruction {
	const char* own_name = "localhost";
	const int own_port = 12121;

	AtomicCounter*	thread_idx = NULL;
	thread_pool*		tp = NULL;
	mock_cluster*		cl = NULL;
	int							listen_fd = -1;
	int							source_port = 0;
	int							saved_proof_wait_ms = 0;

	// the source: a listener that accepts nothing by itself (a connection to
	// it is counted by draining the backlog)
	int open_listener(int& port) {
		int fd = socket(AF_INET, SOCK_STREAM, 0);
		int on = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
		struct sockaddr_in a;
		memset(&a, 0, sizeof(a));
		a.sin_family = AF_INET;
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		a.sin_port = 0;
		if (bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0 || listen(fd, 64) < 0) {
			close(fd);
			return -1;
		}
		socklen_t len = sizeof(a);
		getsockname(fd, (struct sockaddr*)&a, &len);
		port = ntohs(a.sin_port);
		fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
		return fd;
	}

	// connections made to the source since the last call
	int drain_connections() {
		int n = 0;
		for (;;) {
			int c = accept(listen_fd, NULL, NULL);
			if (c < 0) {
				break;
			}
			close(c);
			n++;
		}
		return n;
	}

	long now_ms() {
		struct timeval tv;
		gettimeofday(&tv, NULL);
		return tv.tv_sec * 1000L + tv.tv_usec / 1000;
	}

	struct run_ctx {
		handler_reconstruction* h;
		int rc;
		volatile bool done;
	};

	void* run_handler(void* p) {
		run_ctx* ctx = static_cast<run_ctx*>(p);
		ctx->rc = ctx->h->run();
		__sync_synchronize();
		ctx->done = true;
		return NULL;
	}

	bool wait_done(run_ctx& ctx, int budget_ms) {
		const long end = now_ms() + budget_ms;
		while (!ctx.done && now_ms() < end) {
			usleep(20 * 1000);
		}
		return ctx.done;
	}

	bool wait_state(shared_thread t, const string& state, int budget_ms) {
		const long end = now_ms() + budget_ms;
		while (now_ms() < end) {
			if (t->get_state() == state) {
				return true;
			}
			usleep(10 * 1000);
		}
		return false;
	}

	void setup() {
		stats_object = new stats();
		stats_object->update_timestamp();
		thread_idx = new AtomicCounter(1);
		tp = new thread_pool(1, 128, thread_idx);
		cl = new mock_cluster(own_name, own_port);
		listen_fd = open_listener(source_port);
		saved_proof_wait_ms = handler_reconstruction::source_proof_wait_ms;
		// an attempt against the (silent) source ends quickly
		handler_reconstruction::source_proof_wait_ms = 300;
	}

	void teardown() {
		handler_reconstruction::source_proof_wait_ms = saved_proof_wait_ms;
		if (listen_fd >= 0) {
			close(listen_fd);
			listen_fd = -1;
		}
		tp->shutdown();
		delete tp;
		tp = NULL;
		delete thread_idx;
		thread_idx = NULL;
		delete cl;
		cl = NULL;
		delete stats_object;
		stats_object = NULL;
	}

	// partition 0: master = the source, this node in the given role
	void map_with_self_as(cluster::role r, cluster::state s) {
		cluster::node master = cl->set_node_locked("127.0.0.1", source_port, cluster::role_master, cluster::state_active, 0);
		cl->set_node_locked(own_name, own_port, r, s, r == cluster::role_proxy ? -1 : 0);
		if (r == cluster::role_slave) {
			cluster::node slave[1] = { cl->get_node(own_name, own_port) };
			cl->set_partition(0, master, slave, 1);
		} else {
			cl->set_partition(0, master);
		}
	}

	handler_reconstruction* new_handler(shared_thread t) {
		return new handler_reconstruction(t, cl, NULL, "127.0.0.1", source_port, 0, 0, cluster::role_slave, 0, 0);
	}

	// stops a handler that is still retrying (a failed assertion must not
	// leave it running)
	void stop(shared_thread t, pthread_t th, run_ctx& ctx) {
		t->shutdown(false, true);
		wait_done(ctx, 10000);
		pthread_join(th, NULL);
		delete ctx.h;
	}

	// (1)-(3): a slave whose own node is a proxy in its map from the start is
	// abandoned at the first attempt: -1, no source attempt (_run_once sets the
	// peer and "connect" first; the source sees no connection), stats aborted
	void test_reconstruction_of_a_slave_that_is_a_proxy_in_its_map_is_abandoned_before_any_source_attempt() {
		cut_assert_true(listen_fd >= 0);
		map_with_self_as(cluster::role_proxy, cluster::state_active);
		shared_thread t = tp->get(thread_pool::thread_type_reconstruction);
		run_ctx ctx;
		ctx.h = new_handler(t);
		ctx.rc = 0;
		ctx.done = false;
		pthread_t th;
		pthread_create(&th, NULL, run_handler, &ctx);
		const bool done = wait_done(ctx, 3000);
		const string state_seen = t->get_state();
		const string peer_seen = t->get_thread_info().peer_name;
		const int connections = drain_connections();
		const string rstate = stats_object->get_reconstruction_current_state();
		stop(t, th, ctx);

		cut_assert_true(done, cut_message("the handler did not end (thread state=%s)", state_seen.c_str()));
		cut_assert_equal_int(-1, ctx.rc);
		cut_assert_true(state_seen != "connect", cut_message("thread state=%s", state_seen.c_str()));
		cut_assert_equal_string("", peer_seen.c_str());
		cut_assert_equal_int(0, connections);
		cut_assert_equal_string("aborted", rstate.c_str());
	}

	// the real case: a slave demoted to a proxy WHILE it retries ends at the
	// next attempt, with no connection to the source after the demotion
	void test_reconstruction_of_a_slave_demoted_to_a_proxy_while_retrying_ends_at_the_next_attempt() {
		cut_assert_true(listen_fd >= 0);
		map_with_self_as(cluster::role_slave, cluster::state_prepare);
		shared_thread t = tp->get(thread_pool::thread_type_reconstruction);
		run_ctx ctx;
		ctx.h = new_handler(t);
		ctx.rc = 0;
		ctx.done = false;
		pthread_t th;
		pthread_create(&th, NULL, run_handler, &ctx);

		// attempt 1 goes to the source (not proven: fails, retries in 2 s)
		const bool attempted = wait_state(t, "connect", 5000);
		cl->set_node_locked(own_name, own_port, cluster::role_proxy, cluster::state_active, -1);
		usleep(1000 * 1000);	// attempt 1's bounded proof wait (300 ms) is over
		const long wd = now_ms() + 3000;
		while (handler_reconstruction::outstanding_probe_workers() > 0 && now_ms() < wd) {
			usleep(20 * 1000);
		}
		const bool still_running_after_attempt_1 = !ctx.done;
		const int before = drain_connections();
		t->set_state("demoted");	// a new _run_once would set "connect"

		const bool done = wait_done(ctx, 5000);
		const string state_seen = t->get_state();
		const int after = drain_connections();
		const string rstate = stats_object->get_reconstruction_current_state();
		stop(t, th, ctx);

		cut_assert_true(attempted, cut_message("attempt 1 did not reach the source"));
		cut_assert_true(still_running_after_attempt_1, cut_message("ended within attempt 1 (rc=%d)", ctx.rc));
		cut_assert_true(before >= 1, cut_message("attempt 1 made no connection to the source"));
		cut_assert_true(done, cut_message("not abandoned at the next attempt (thread state=%s)", state_seen.c_str()));
		cut_assert_equal_int(-1, ctx.rc);
		cut_assert_equal_string("demoted", state_seen.c_str());
		cut_assert_equal_int(0, after);
		cut_assert_equal_string("aborted", rstate.c_str());
	}

	// (4) control: a node that is a slave of the partition is NOT abandoned by
	// that check: it attempts against the source and keeps retrying ("running")
	// until it is stopped
	void test_reconstruction_of_a_slave_of_the_partition_is_not_abandoned_and_retries() {
		cut_assert_true(listen_fd >= 0);
		map_with_self_as(cluster::role_slave, cluster::state_prepare);
		shared_thread t = tp->get(thread_pool::thread_type_reconstruction);
		run_ctx ctx;
		ctx.h = new_handler(t);
		ctx.rc = 0;
		ctx.done = false;
		pthread_t th;
		pthread_create(&th, NULL, run_handler, &ctx);

		const bool attempted = wait_state(t, "connect", 5000);
		usleep(1500 * 1000);	// attempt 1 failed (300 ms); now in its 2 s retry wait
		const bool running = !ctx.done;
		const string peer_seen = t->get_thread_info().peer_name;
		const int connections = drain_connections();
		const string rstate = stats_object->get_reconstruction_current_state();

		t->shutdown(false, true);
		const bool done = wait_done(ctx, 5000);
		const string rstate_after = stats_object->get_reconstruction_current_state();
		pthread_join(th, NULL);
		delete ctx.h;

		cut_assert_true(attempted, cut_message("no attempt against the source"));
		cut_assert_true(running, cut_message("ended without a shutdown request (rc=%d)", ctx.rc));
		cut_assert_equal_string("127.0.0.1", peer_seen.c_str());
		cut_assert_true(connections >= 1, cut_message("no connection to the source"));
		cut_assert_equal_string("running", rstate.c_str());
		cut_assert_true(done);
		cut_assert_equal_int(-1, ctx.rc);
		cut_assert_equal_string("aborted", rstate_after.c_str());
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
