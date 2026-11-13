/**
 *	signal_interrupt.cc
 */
#include "signal_interrupt.h"

namespace gree {
namespace flare {

extern "C" void sigusr1_interrupt_handler(int sig) {
	(void)sig;		// the delivery interrupts the blocking call; nothing else
}

}	// namespace flare
}	// namespace gree
