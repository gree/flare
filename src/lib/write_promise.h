/**
 *	write_promise.h
 *
 *	C' (docs/design-node-operations-2026-10-19.md §13): the successor's
 *	PROMISE and the promotion gate, on top of the write authority engine in
 *	write_fence.h. Everything here is OFF unless configure() enabled it
 *	(flared option write-authority-enabled); there are no default numbers.
 *
 *	A REPLICA of a partition, while FOLLOWING, promises its master not to be
 *	promoted until the promise has expired on ITS OWN clock: it records
 *	promise_end = receive time + ttl + margin BEFORE it answers, so the end
 *	is never earlier than the master's deadline (send point + ttl). On the
 *	operator's prepare it stops promising (PREPARING; an issued promise keeps
 *	its end). It leaves PREPARING only by the operator's cancel (the same
 *	terminal CAS decision) — never by a timer (Unknown never resumes).
 *	It may be promoted only when the intent is COMMITTED (the operator tells
 *	it after the CAS applied), its last promise has expired and the quiet
 *	time after its own start (max-ttl + margin: a restart forgets promises)
 *	has passed (may_promote). The cluster's role shift asks may_promote.
 *
 *	A MASTER holds the operator-given membership of its partition: solo (no
 *	successor, an unlimited grant), or the successors it asks for promises.
 *	The authority thread (handler_authority) sends one request round per
 *	renew interval to ALL successors with ONE nonce taken at the send point;
 *	only when every successor answered PROMISED is the grant applied.
 *
 *	Time is the write_fence authority clock (CLOCK_BOOTTIME, injectable).
 */
#ifndef	WRITE_PROMISE_H
#define	WRITE_PROMISE_H

#include <pthread.h>
#include <stdint.h>
#include <map>
#include <string>
#include <vector>

namespace gree {
namespace flare {

class write_promise {
public:
	enum state { st_following = 0, st_preparing, st_committed, st_promoted };

	/** switch the feature on (enabled) or off; margin_ms / max_ttl_ms are required (> 0)
	    when enabled. Records the start time of this process on the authority clock. */
	static bool configure(bool enabled, uint64_t margin_ms, uint64_t max_ttl_ms, std::string& why);
	static bool enabled();
	/** test seam: is this node a slave of `partition` (default: always true) */
	static void set_role_probe(bool (*is_slave)(int partition));

	struct status {
		status(): st(st_following), intent(0), term_next(0), have_promise(false), remaining_ms(0), promotable(false) { }
		state		st;
		uint64_t	intent;
		uint64_t	term_next;
		bool		have_promise;
		uint64_t	remaining_ms;	// until promise end / quiet time have passed (0 = passed)
		bool		promotable;		// committed and remaining_ms == 0
	};

	/** REPLICA: a master's request. true -> reply PROMISED (the end is recorded). */
	static bool promise(uint32_t partition, uint64_t term, uint64_t generation, uint64_t ttl_ms, std::string& why);
	static bool prepare(uint32_t partition, uint64_t intent, uint64_t term_next, status& out, std::string& why);
	static bool commit(uint32_t partition, uint64_t intent, status& out, std::string& why);
	static bool cancel(uint32_t partition, uint64_t intent, status& out, std::string& why);
	static status get_status(uint32_t partition);
	/** the promotion gate: true when this node may become master of `partition` now
	    (then it is recorded as PROMOTED). `why` says what is missing. */
	static bool may_promote(uint32_t partition, std::string& why);
	/** the node is (not) the master of `partition`; a demotion returns PROMOTED to FOLLOWING */
	static void note_role(uint32_t partition, bool master);

	/** MASTER: the operator's membership of the partition. successors are node keys. */
	struct members {
		members(): partition(0), term(0), generation(0), solo(false), ttl_ms(0), renew_ms(0) { }
		uint32_t				partition;
		uint64_t				term, generation;
		bool					solo;
		uint64_t				ttl_ms, renew_ms;
		std::vector<std::string>	successors;
	};
	static bool set_members(uint32_t partition, uint64_t term, uint64_t generation, uint64_t ttl_ms,
		uint64_t renew_ms, const std::vector<std::string>& successors, std::string& why);
	/** solo: applies an unlimited grant for (term, generation) at once */
	static bool set_solo(uint32_t partition, uint64_t term, uint64_t generation, std::string& why);
	static bool get_members(uint32_t partition, members& out);
	static std::vector<uint32_t> member_partitions();
	/** replica side of the floor the operator gives (never lowers) */
	static bool set_floor(uint32_t partition, uint64_t term, uint64_t generation, std::string& why);

	/** one request round for a partition's members: begin (records the send point), then
	    finish with the number of successors that answered PROMISED. Returns the nonce (0: none). */
	static uint64_t begin_round(const members& m);
	static bool finish_round(const members& m, uint64_t nonce, size_t promised, std::string& why);

	static void reset_for_test();

private:
	struct rstate {
		rstate(): st(st_following), intent(0), term_next(0), have_end(false), end_ns(0) { }
		state st;
		uint64_t intent, term_next;
		bool have_end;
		uint64_t end_ns;
	};
	static status _status_locked(const rstate& r, uint64_t now);
	static uint64_t _quiet_until_locked();
	static pthread_mutex_t	_m;
	static bool				_enabled;
	static uint64_t			_margin_ns, _max_ttl_ns, _boot_ns;
	static bool				(*_is_slave)(int);
	static std::map<uint32_t, rstate>	_r;
	static std::map<uint32_t, members>	_members;
};

}	// namespace flare
}	// namespace gree

#endif	// WRITE_PROMISE_H
