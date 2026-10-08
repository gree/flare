/**
 *	signal_interrupt.h
 *
 *	SIGUSR1 is sent only to INTERRUPT a blocking call in a thread being shut
 *	down (thread::shutdown -> pthread_kill). Its handler must be
 *	async-signal-safe: it used to call log_notice, which builds strings,
 *	allocates and writes through the logger — a thread interrupted while it
 *	held one of those internal locks (the allocator's, the logger's) could
 *	block on itself, and every thread that logged or allocated after it with
 *	it (review 2026-10-08: a candidate for CI 37770467697, where a promoted
 *	node stopped right after 'stopping continuous replication follower'; not
 *	established as that run's cause). The handler only counts.
 */
#ifndef	SIGNAL_INTERRUPT_H
#define	SIGNAL_INTERRUPT_H

#include <signal.h>

namespace gree {
namespace flare {

// how many SIGUSR1 interrupts were received (read from a normal thread)
long sigusr1_received_count();

// the SIGUSR1 handler: async-signal-safe (no logging, no allocation, errno kept)
extern "C" void sigusr1_interrupt_handler(int sig);

}	// namespace flare
}	// namespace gree

#endif
