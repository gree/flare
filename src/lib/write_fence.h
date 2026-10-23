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
 *	ROLE-AWARE, PER PARTITION. Every mutation entry declares what it is
 *	before it writes (entry::admit_master / entry::admit_replica):
 *	- MASTER-WRITE (a client write this node applies as the master of the
 *	  partition, the reaper, a lazy expiry delete, flush_all, a snapshot
 *	  push that lands on the master): needs the valid grant OF THAT
 *	  PARTITION; a grant of another partition, or none, refuses it;
 *	- REPLICA-APPLY (a change applied because this node is a replica of the
 *	  partition: a forwarded / proxied / identified change, a snapshot relay
 *	  hop): needs NO master grant. It must carry the authority it was made
 *	  under (partition, term, generation: the "wa=" token) and is refused
 *	  when that is older than the partition's FLOOR (the newest authority
 *	  this node knows: raised by a change that carries a newer one, by a
 *	  grant, or by authority_set_floor), when it carries none, or when this
 *	  node holds a valid master grant for the partition itself;
 *	- INTERNAL: see docs §12.6 for the decision per entry.
 *	Raising the floor, like a revoke or a new term, drains the apply sections
 *	(exclusive _apply_rw, node-wide), so a replica change admitted under an
 *	older term cannot apply after the newer one was admitted.
 *	An entry that never declared a role is refused when the engine is on.
 */
#ifndef	WRITE_FENCE_H
#define	WRITE_FENCE_H

#include <pthread.h>
#include <stdint.h>
#include <time.h>
#include <map>
#include <set>
#include <string>

namespace gree {
namespace flare {

class write_fence {
public:
	/** install (or, with NULL, remove) the sink of the write trace (see entry::trace_applied). Off by
	    default; flared installs it only with write-authority-trace (tests): a line per applied mutation. */
	static void trace_set_sink(void (*sink)(const std::string& line));

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
		/** MASTER-WRITE: this mutation is applied as the master of
		    `partition` (< 0: unknown, refused when the engine is on). Takes the
		    grant of THAT partition. Returns false (and fenced() becomes true,
		    refusal() "no write authority") when the engine is on and that
		    partition has no valid grant. Engine off: true, nothing bound. */
		bool admit_master(int partition);
		/** REPLICA-APPLY: this mutation is a change applied because this node
		    is a replica of `partition`; `tag` is the authority token the
		    change carries (see authority_tag). No master grant is needed; the
		    change is refused when the tag is missing / malformed / for another
		    partition / older than the partition's floor, or when this node is
		    the master of the partition. Engine off: true, tag ignored. */
		bool admit_replica(int partition, const std::string& tag);
		/** the token a MASTER-WRITE carries to its replicas ("p:term:gen"),
		    empty when the entry was not admitted as a master under the engine */
		std::string authority_tag() const;
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
		/** WRITE TRACE (off unless a sink is installed, see trace_set_sink): call after the storage write
		    of a mutation that was applied (stored / deleted / incremented). Emits ONE line naming the
		    operation, the key, the role this node applied it in (master / replica / unbound), the
		    partition, the authority's term / generation / solo flag, this node's monotonic clock (ns) and
		    its identity (boot id, copy id): the direct evidence of WHICH node applied an acknowledged
		    write as the master. Only entries whose apply_begin() succeeded are traced. */
		void trace_applied(const char* op, const std::string& key);
		/** the same check for a step that is not held (the forward to the
		    replicas): true when the admitted authority is still current. */
		bool still_authorized();
	private:
		friend class write_fence;
		bool _fenced;
		bool _no_authority;
		bool _bound;
		bool _bound_replica;
		bool _applying;
		bool _bound_solo;
		bool _applied;
		bool _admit_master(int partition);
		bool _admit_replica(int partition, const std::string& tag);
		uint32_t _bound_partition;
		uint64_t _bound_serial;
		uint64_t _bound_deadline;
		uint64_t _bound_term;
		uint64_t _bound_gen;
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
	/** a valid grant is held now (for the default partition: the last one given to authority_set_identity) */
	static bool authority_valid();
	static bool authority_valid(uint32_t partition);
	/** the token to hand to a replica for what this node does as the master of
	    `partition` right now ("p:term:gen"); empty when engine off / no valid grant */
	static std::string authority_current_tag(uint32_t partition);
	/** per partition request / revoke (the no-argument forms use the default partition) */
	static uint64_t authority_begin_request(uint32_t partition);
	/** the newest authority this node knows for a partition (a replica's
	    reference); raising it above a held grant voids that grant. Never lowers. */
	static void authority_set_floor(uint32_t partition, uint64_t term, uint64_t generation);
	static bool authority_floor(uint32_t partition, uint64_t& term, uint64_t& generation);
	/** "p:term:gen" parse / format of the token a replica change carries */
	static bool authority_parse_tag(const std::string& tag, uint32_t& partition, uint64_t& term, uint64_t& generation);
	/** how many mutations were refused for lack of authority (admission or ack) */
	static uint64_t authority_refused();
	/** how many times a change of authority (revoke / new term / floor raise) had to wait for a write in its apply section */
	static uint64_t authority_drain_waits();
	/** register `partition` with this node's identity WITHOUT clearing a grant already held
	    when the identity is unchanged (authority_set_identity clears it). */
	static void authority_ensure_identity(uint32_t partition, const std::string& pod_uid,
		const std::string& boot_id, const std::string& copy_id);
	/** the node's own authority clock now (authority_clock_failed when unreadable) */
	static uint64_t authority_now_ns();
	/** what this node holds for a partition: false when no grant. `remaining_ns` is 0 for solo */
	static bool authority_info(uint32_t partition, uint64_t& term, uint64_t& generation, bool& solo, uint64_t& remaining_ns);
	/** this node's identity strings (for the grant a request is answered with) */
	static void authority_identity(std::string& pod_uid, std::string& boot_id, std::string& copy_id);
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
	/** test seam: called (outside the lock) right after admit_master / admit_replica
	    ADMITTED an entry, i.e. between the admission and the apply section */
	static void set_admit_hook(void (*hook)());
	static void reset_for_test();

private:
	static bool _active_locked(time_t now);
	struct part_state {
		part_state(): have(false), term(0), gen(0), deadline(0), solo(false), serial(0),
			revoked(false), revoked_term(0), revoked_gen(0), last_nonce(0),
			floor_set(false), floor_term(0), floor_gen(0), floor_serial(0) { }
		bool have;
		uint64_t term, gen, deadline;
		bool solo;
		uint64_t serial;
		bool revoked;
		uint64_t revoked_term, revoked_gen;
		uint64_t last_nonce;
		std::map<uint64_t, uint64_t> pending;	// nonce -> send point (ns)
		bool floor_set;
		uint64_t floor_term, floor_gen;
		uint64_t floor_serial;
	};
	static bool _authority_valid_locked(const part_state& ps, uint64_t now);
	static bool _bound_ok_locked(const entry& e, uint64_t now);
	static bool _apply_grant_locked(const authority_grant& g, std::string& why);
	static void _clear_grant_locked(part_state& ps);
	static void _refuse_admission_locked(entry& e);

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
	static void				(*_admit_hook)();

	static bool				_auth_enabled;
	static bool				_auth_identity_set;
	static uint32_t			_auth_partition;	// the default partition of the no-argument forms
	static std::string		_auth_pod_uid, _auth_boot_id, _auth_copy_id;
	static uint64_t			_auth_next_nonce;
	static std::map<uint32_t, part_state>	_auth_parts;
	static std::set<uint32_t>	_auth_registered;
	static uint64_t			_auth_refused;
	static void				(*_trace_sink)(const std::string& line);
	static uint64_t			(*_auth_clock)();
};

}	// namespace flare
}	// namespace gree

#endif	// WRITE_FENCE_H
