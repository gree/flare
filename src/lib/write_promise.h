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

	/** the COMPLETE scope of one promotion intent on the wire: prepare / commit / cancel all carry
	    it and are matched against it as a whole (a delayed command of another term, membership
	    generation, intent id or receiver incarnation changes nothing). `boot` / `copy` are the
	    RECEIVER's flared boot id and persistent copy id as the operator read them (identity()). */
	struct scope {
		scope(): intent(0), term_next(0), generation(0) { }
		uint64_t	intent, term_next, generation;
		std::string	boot, copy;
		bool operator==(const scope& o) const {
			return intent == o.intent && term_next == o.term_next && generation == o.generation && boot == o.boot && copy == o.copy;
		}
	};

	struct status {
		status(): st(st_following), intent(0), term_next(0), generation(0), have_promise(false), remaining_ms(0), promotable(false) { }
		state		st;
		uint64_t	intent;
		uint64_t	term_next;
		uint64_t	generation;
		std::string	boot, copy;		// the scope's receiver identity (the prepared one; the current one when following)
		bool		have_promise;
		uint64_t	remaining_ms;	// until promise end / quiet time have passed (0 = passed)
		bool		promotable;		// committed and remaining_ms == 0
	};

	/** REPLICA: a master's request. true -> reply PROMISED (the end is recorded). */
	static bool promise(uint32_t partition, uint64_t term, uint64_t generation, uint64_t ttl_ms, std::string& why);
	static bool prepare(uint32_t partition, const scope& sc, status& out, std::string& why);
	static bool commit(uint32_t partition, const scope& sc, status& out, std::string& why);
	static bool cancel(uint32_t partition, const scope& sc, status& out, std::string& why);
	/** this node's identity as the operator binds an intent to it: the flared process boot id and
	    the persistent copy id of the storage (a snapshot swap / copy replacement changes it). */
	static void identity(std::string& boot, std::string& copy);
	/** test / flared seam: where identity() reads the two ids (default: this process's start
	    time and "-"). The probe must not take write_promise's lock. */
	static void set_identity_probe(void (*probe)(std::string& boot, std::string& copy));
	/** the operator proved a FRESH FIRST BUILD of `partition` (no copy has ever held it: the
	    authoritative history says so) for this incarnation of this node: a Proxy -> master shift
	    of the partition is then allowed once without an intent. Anything else (an existing copy
	    returning from Proxy to master) goes through the intent like a slave. */
	static bool allow_first_build(uint32_t partition, const std::string& boot, const std::string& copy, std::string& why);
	/** a Proxy -> master shift: true when a first build was allowed for this incarnation (consumed) */
	static bool may_first_build(uint32_t partition, std::string& why);
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
		std::string				boot, copy;		// the identity (flared boot id, persistent copy id) the membership and its grants are bound to
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
		rstate(): st(st_following), have_end(false), end_ns(0) { }
		state st;
		scope sc;		// the prepared intent (empty when following)
		bool have_end;
		uint64_t end_ns;
	};
	struct first_build {
		first_build(): until_ns(0) { }
		std::string boot, copy;
		uint64_t until_ns;
	};
	static status _status_locked(const rstate& r, uint64_t now, const std::string& boot, const std::string& copy);
	static void _revalidate_locked(rstate& r, const std::string& boot, const std::string& copy);
	static void _identity_locked(std::string& boot, std::string& copy);
	static void _rebind_locked();
	static uint64_t _quiet_until_locked();
	static pthread_mutex_t	_m;
	static bool				_enabled;
	static uint64_t			_margin_ns, _max_ttl_ns, _boot_ns;
	static bool				(*_is_slave)(int);
	static void				(*_identity_probe)(std::string&, std::string&);
	static std::map<uint32_t, rstate>	_r;
	static std::map<uint32_t, members>	_members;
	static std::map<uint32_t, first_build>	_first;
};

}	// namespace flare
}	// namespace gree

#endif	// WRITE_PROMISE_H
