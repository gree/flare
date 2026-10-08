/**
 *	test_signal_interrupt.cc
 *
 *	The SIGUSR1 interrupt handler (signal_interrupt.h) is async-signal-safe:
 *	it keeps errno, only counts, and a thread interrupted thousands of times
 *	while it allocates and formats strings keeps making progress (the old
 *	handler logged — allocated and locked — inside the handler).
 */
#include <cppcutter.h>
#include <signal_interrupt.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <signal.h>
#include <sstream>
#include <string>
#include <unistd.h>

using namespace std;
using namespace gree::flare;

namespace test_signal_interrupt {
	volatile int g_done = 0;
	volatile long g_iterations = 0;

	void* worker(void*) {
		for (long i = 0; i < 200000; i++) {
			ostringstream s;
			s << "allocating and formatting while interrupted " << i;
			string t = s.str();
			char* p = new char[64 + (i % 512)];
			snprintf(p, 64, "%ld %s", i, t.c_str());
			delete[] p;
			g_iterations = i + 1;
		}
		g_done = 1;
		return NULL;
	}

	void setup() {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = sigusr1_interrupt_handler;
		sigaction(SIGUSR1, &sa, NULL);
	}

	void test_handler_keeps_errno_and_counts() {
		const long before = sigusr1_received_count();
		errno = EAGAIN;
		sigusr1_interrupt_handler(SIGUSR1);
		cut_assert_equal_int(EAGAIN, errno);
		cut_assert_equal_int(before + 1, sigusr1_received_count());
	}

	void test_interrupted_thread_keeps_making_progress() {
		g_done = 0;
		g_iterations = 0;
		const long before = sigusr1_received_count();
		pthread_t t;
		cut_assert_equal_int(0, pthread_create(&t, NULL, worker, NULL));
		int sent = 0;
		for (int i = 0; i < 20000 && !g_done; i++) {
			if (pthread_kill(t, SIGUSR1) == 0) sent++;
			if (i % 50 == 0) usleep(100);
		}
		// bounded wait for completion: a thread that blocked on itself
		// inside the handler would never finish
		for (int w = 0; w < 600 && !g_done; w++) {
			usleep(100 * 1000);
		}
		cut_assert_true(g_done, cut_message("the interrupted thread stopped after %ld iterations (%d signals sent)", (long)g_iterations, sent));
		pthread_join(t, NULL);
		cut_assert_operator(sigusr1_received_count(), >, before);
	}
}
