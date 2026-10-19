/**
 *	write_fence.h
 *
 *	Planned-eviction write fence (docs/design-node-operations-2026-10-19.md,
 *	docs/review-safe-eviction-2026-10-14.md §4.3 step 2-3). While armed, this
 *	node refuses EVERY new mutation with an explicit error (client writes,
 *	writes proxied to it, cross-cluster deliveries, flush_all, snapshot push,
 *	orphan purge) and stops its own background mutations (expire reaper, lazy
 *	expiry deletes). Mutations that entered before the fence are counted in
 *	flight; when the fence is armed and the count is 0, every mutation that
 *	passed the check has finished its local apply, so the latest sequence
 *	number read afterwards is a fixed barrier.
 *
 *	The fence carries the operator's token and a TTL: if the operator does not
 *	re-arm it, it releases by itself and the node takes writes again (a lost
 *	operator never leaves a master fenced for ever).
 *
 *	The check and the in-flight increment happen under ONE mutex, so a
 *	mutation either is refused or is counted before `arm` returns — the
 *	ordering the barrier relies on (relaxed atomics would not give it).
 *
 *	GENERATION: every time the fence goes from not armed to armed (a first
 *	arm, or an arm after a release or after the TTL lapsed) the generation is
 *	incremented; a same-token re-arm of a fence still armed keeps it. Two
 *	readings with the same generation (and the same boot) therefore prove the
 *	fence was armed WITHOUT A GAP in between, so no mutation was accepted
 *	between them. A barrier read under generation g is valid only while the
 *	fence is still at g: after a lapse, writes may have been acknowledged
 *	after the barrier (review 2026-10-19 #1).
 */
#ifndef	WRITE_FENCE_H
#define	WRITE_FENCE_H

#include <pthread.h>
#include <stdint.h>
#include <time.h>
#include <string>

namespace gree {
namespace flare {

class write_fence {
public:
	/** arm (or re-arm with the SAME token, extending the TTL). Fails when
	    another token holds an unexpired fence or the arguments are invalid.
	    `why` names the reason on failure. */
	static bool arm(const std::string& token, uint32_t ttl_sec, std::string& why);
	/** release a fence held by `token` (true), or when none is armed (true);
	    false when ANOTHER token holds it. */
	static bool release(const std::string& token);
	/** armed now (an expired fence is released here) */
	static bool active();
	static std::string token();
	/** seconds until the TTL releases the fence, 0 when not armed */
	static uint32_t remaining_sec();
	/** mutations that entered before the fence and have not finished */
	static uint64_t in_flight();
	/** how many mutations were refused since start */
	static uint64_t refused();
	/** the fence generation (0 = never armed since start; see above) */
	static uint64_t generation();

	/** one consistent reading of every field (one lock) */
	struct status {
		bool		active;
		std::string	token;
		uint32_t	remaining_sec;
		uint64_t	in_flight;
		uint64_t	refused;
		uint64_t	generation;
	};
	static status snapshot();

	/** RAII entry of one mutation: refused (fenced) or counted in flight. */
	class entry {
	public:
		entry();
		~entry();
		bool fenced() const { return this->_fenced; }
	private:
		bool _fenced;
		entry(const entry&);
		entry& operator=(const entry&);
	};

	/** test seam: a clock in seconds (default time(NULL)) */
	static void set_clock(time_t (*clock)());
	/** test seam: called (outside the lock) right after an entry is ADMITTED
	    and counted, i.e. between the fence check and the mutation it guards
	    — a test arms the fence there to prove the mutation is counted */
	static void set_entry_hook(void (*hook)());
	static void reset_for_test();

private:
	static bool _active_locked(time_t now);

	static pthread_mutex_t	_mutex;
	static bool				_armed;
	static std::string		_token;
	static time_t			_expires;
	static uint64_t			_in_flight;
	static uint64_t			_refused;
	static uint64_t			_generation;
	static time_t			(*_clock)();
	static void				(*_entry_hook)();
};

}	// namespace flare
}	// namespace gree

#endif	// WRITE_FENCE_H
