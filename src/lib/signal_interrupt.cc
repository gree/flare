/**
 *	signal_interrupt.cc
 */
#include "signal_interrupt.h"

#include <cerrno>

namespace gree {
namespace flare {

static volatile sig_atomic_t g_sigusr1_received = 0;

extern "C" void sigusr1_interrupt_handler(int sig) {
	const int saved = errno;
	(void)sig;
	g_sigusr1_received = g_sigusr1_received + 1;
	errno = saved;
}

long sigusr1_received_count() {
	return static_cast<long>(g_sigusr1_received);
}

}	// namespace flare
}	// namespace gree
