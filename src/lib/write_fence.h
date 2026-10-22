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
 *
 *	WRITE AUTHORITY (C', docs/design-node-operations-2026-10-19.md §12, §12.6):
 *	the same check path also carries a time-bounded, term-ordered authority
 *	to MASTER writes, so a silent old master (cut from the control plane,
 *	still reachable by clients) stops acknowledging after its authority
 *	ends. It is OFF by default (no behaviour change) and is switched on only
 *	through authority_set_enabled (a test/admin seam). While on, an entry is
 *	refused unless a valid grant is held, and the grant seen at admission is
 *	the one that must still be current when the mutation is acknowledged
 *	(entry::ack_ok). Rules:
 *	- a grant is bound to partition, term, membership generation, this
 *	  node's pod UID / boot id / copy id, and the nonce of the request this
 *	  node itself sent;
 *	- time is the node's own CLOCK_BOOTTIME; the deadline is the REQUEST SEND
 *	  point + ttl, so a late reply never extends it;
 *	- a reply for a request that is not pending (old, duplicate, from before a
 *	  restart), for an older term/generation, or at or below a revoke, is
 *	  refused; a revoke wins over a later-arriving older grant;
 *	- a `solo` grant (the authoritative membership says there is no
 *	  successor) has no deadline; an unreachable operator is only expiry.
 *	- the grant is checked again where the mutation is applied: an entry
 *	opens an apply section (entry::apply_begin) right before the storage
 *	write, so an entry whose authority was revoked, replaced (term /
 *	generation), re-identified, or whose own deadline passed neither
 *	mutates storage nor forwards (the ACK check alone would be too late);
 *	- a routine renewal (same term and generation) does not change the
 *	authority: an entry keeps the deadline it was admitted with and may
 *	finish within it, never re-mapped to the new TTL.
 *	LOCK ORDER (audited): _apply_rw (shared by entries across the storage
 *	write; exclusive for a change of authority, which therefore drains the
 *	writes in flight) -> storage wholelock -> key slot lock; _mutex is
 *	innermost, held only for a few loads/stores, never across the storage
 *	write, a forward, a sleep or a callback, and never while taking another
 *	lock. Nothing under a slot lock takes _apply_rw. A renewal takes no
 *	exclusive lock.
 *	Not yet role-aware: while on, the node-level check also gates a
 *	replica's apply paths, so the seam must not be enabled in production.
 */
#ifndef	WRITE_FENCE_H
#define	WRITE_FENCE_H

#include <pthread.h>
#include <stdint.h>
#include <time.h>
#include <map>
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
		/** the SERVER_ERROR text of a refusal ("fenced" or "no write authority") */
		const char* refusal() const { return this->_no_authority ? "no write authority" : "fenced"; }
		/** call right before the ACK of the mutation: true when the grant
		    admitted with this entry is still the current, unexpired one (a
		    renewed or replaced grant counts as different: refuse). Always
		    true when the authority engine was off at admission and is off. */
		bool ack_ok();
		/** call right before the STORAGE WRITE of the mutation and keep it
		    until the write has returned (apply_end, or the destructor): true
		    when the authority admitted with this entry is still the current
		    one and its OLD deadline has not passed. While an apply section is
		    open, no revoke / new term / generation / identity change becomes
		    effective (it waits, see LOCK ORDER), so an entry that got true
		    has written under the authority it was admitted with. False: the
		    mutation must NOT write. Always true when the engine was off at
		    admission and is off. */
		bool apply_begin();
		void apply_end();
		/** the same check for a step that is not held (the forward to the
		    replicas): true when the admitted authority is still current. */
		bool still_authorized();
	private:
		friend class write_fence;
		bool _fenced;
		bool _no_authority;
		bool _bound;
		bool _applying;
		bool _bound_solo;
		uint64_t _bound_serial;
		uint64_t _bound_deadline;
		entry(const entry&);
		entry& operator=(const entry&);
	};

	/** a grant reply (see WRITE AUTHORITY above) */
	struct authority_grant {
		authority_grant(): partition(0), term(0), generation(0), nonce(0), ttl_ns(0), solo(false) { }
		uint32_t	partition;
		uint64_t	term;
		uint64_t	generation;		// membership generation
		std::string	pod_uid;
		std::string	boot_id;
		std::string	copy_id;
		uint64_t	nonce;			// of the request this node sent
		uint64_t	ttl_ns;			// from the request send point; ignored when solo
		bool		solo;			// authoritative membership: no successor
	};
	/** test/admin seam: engine on/off (default off). Switching it clears every grant. */
	static void authority_set_enabled(bool on);
	static bool authority_enabled();
	/** this node's identity; a grant for another one is refused */
	static void authority_set_identity(uint32_t partition, const std::string& pod_uid,
		const std::string& boot_id, const std::string& copy_id);
	/** the node asks for (or renews) a grant NOW: records the send point on
	    the node's own boottime clock and returns the request nonce */
	static uint64_t authority_begin_request();
	/** install a grant reply; false (and `why`) when refused */
	static bool authority_apply_grant(const authority_grant& g, std::string& why);
	/** revoke every grant of (term, generation) and below for the partition */
	static bool authority_revoke(uint32_t partition, uint64_t term, uint64_t generation, std::string& why);
	/** a valid grant is held now */
	static bool authority_valid();
	/** how many mutations were refused for lack of authority (admission or ack) */
	static uint64_t authority_refused();
	/** test seam: boottime clock in nanoseconds (default CLOCK_BOOTTIME).
	    A clock that cannot be read returns authority_clock_failed, and
	    everything fails closed (no grant request, no admission, no ack). */
	static void authority_set_clock(uint64_t (*clock)());
	static const uint64_t authority_clock_failed = ~static_cast<uint64_t>(0);
	/** test seam: replaces clock_gettime for the default clock */
	static void authority_set_gettime(int (*gettime)(clockid_t, struct timespec*));

	/** test seam: a clock in seconds (default time(NULL)) */
	static void set_clock(time_t (*clock)());
	/** test seam: called (outside the lock) right after an entry is ADMITTED
	    and counted, i.e. between the fence check and the mutation it guards
	    — a test arms the fence there to prove the mutation is counted */
	static void set_entry_hook(void (*hook)());
	static void reset_for_test();

private:
	static bool _active_locked(time_t now);
	static bool _authority_valid_locked(uint64_t now);
	static bool _bound_ok_locked(const entry& e, uint64_t now);
	static bool _apply_grant_locked(const authority_grant& g, std::string& why);

	static pthread_mutex_t	_mutex;
	static pthread_rwlock_t	_apply_rw;
	static bool				_armed;
	static std::string		_token;
	static time_t			_expires;
	static uint64_t			_in_flight;
	static uint64_t			_refused;
	static uint64_t			_generation;
	static time_t			(*_clock)();
	static void				(*_entry_hook)();

	static bool				_auth_enabled;
	static bool				_auth_identity_set;
	static uint32_t			_auth_partition;
	static std::string		_auth_pod_uid, _auth_boot_id, _auth_copy_id;
	static uint64_t			_auth_next_nonce;
	static uint64_t			_auth_last_nonce;
	static std::map<uint64_t, uint64_t>	_auth_pending;	// nonce -> send point (ns)
	static bool				_auth_have;
	static uint64_t			_auth_term, _auth_gen, _auth_deadline;
	static bool				_auth_solo;
	static uint64_t			_auth_serial;
	static bool				_auth_revoked;
	static uint64_t			_auth_revoked_term, _auth_revoked_gen;
	static uint64_t			_auth_refused;
	static uint64_t			(*_auth_clock)();
};

}	// namespace flare
}	// namespace gree

#endif	// WRITE_FENCE_H
