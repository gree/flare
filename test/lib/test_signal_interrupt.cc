/**
 *	test_signal_interrupt.cc
 *
 *	The SIGUSR1 interrupt handler (signal_interrupt.h) is a no-op: a thread
 *	interrupted thousands of times while it allocates and formats strings
 *	keeps making progress. Run in an ISOLATED CHILD process with a bounded
 *	wait: a child that blocks is killed and reaped, so a failure never
 *	leaves a thread or a handler behind in the test process.
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
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace std;
using namespace gree::flare;

namespace test_signal_interrupt {
	struct shared_state {
		pthread_mutex_t m;
		bool done;
	};

	void* worker(void* arg) {
		shared_state* st = static_cast<shared_state*>(arg);
		for (long i = 0; i < 200000; i++) {
			ostringstream s;
			s << "allocating and formatting while interrupted " << i;
			string t = s.str();
			char* p = new char[64 + (i % 512)];
			snprintf(p, 64, "%ld %s", i, t.c_str());
			delete[] p;
		}
		pthread_mutex_lock(&st->m);
		st->done = true;
		pthread_mutex_unlock(&st->m);
		return NULL;
	}

	// the child: exit 0 when the interrupted worker finished, 2 on a setup error
	int child_run() {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = sigusr1_interrupt_handler;
		sigemptyset(&sa.sa_mask);
		if (sigaction(SIGUSR1, &sa, NULL) != 0) {
			return 2;
		}
		shared_state st;
		pthread_mutex_init(&st.m, NULL);
		st.done = false;
		pthread_t t;
		if (pthread_create(&t, NULL, worker, &st) != 0) {
			return 2;
		}
		for (int i = 0; i < 20000; i++) {
			pthread_mutex_lock(&st.m);
			const bool done = st.done;
			pthread_mutex_unlock(&st.m);
			if (done) break;
			pthread_kill(t, SIGUSR1);
			if (i % 50 == 0) usleep(100);
		}
		pthread_join(t, NULL);	// the parent's bound covers a worker that never returns
		return 0;
	}

	void test_handler_is_a_noop_that_keeps_errno() {
		errno = EAGAIN;
		sigusr1_interrupt_handler(SIGUSR1);
		cut_assert_equal_int(EAGAIN, errno);
	}

	void test_interrupted_thread_keeps_making_progress_in_an_isolated_child() {
		const pid_t pid = fork();
		cut_assert_operator(pid, >=, 0);
		if (pid == 0) {
			_exit(child_run());
		}
		int status = 0;
		pid_t r = 0;
		for (int w = 0; w < 600; w++) {		// 60 s bound
			r = waitpid(pid, &status, WNOHANG);
			if (r == pid) break;
			usleep(100 * 1000);
		}
		if (r != pid) {
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);		// always reaped
			cut_fail("the interrupted child did not finish within 60 s (killed and reaped)");
		}
		cut_assert_true(WIFEXITED(status));
		cut_assert_equal_int(0, WEXITSTATUS(status));
	}
}
