/**
 *	source_eligibility.h
 *
 *	R3 (SAF-10 release checklist): a slave's copy is eligible to answer reads
 *	locally (and to be promoted) only for the SOURCE it was validated against
 *	— its node key, lineage (master_id) and history (source epoch). When the
 *	node accepts a map whose partition master differs, or the master's
 *	history changes under the same name, the eligibility is NOT carried over:
 *	reads go to the master (an explicit error if they cannot be forwarded)
 *	until the copy is re-validated against the current master.
 *
 *	This header holds the pure decision, so it can be unit-tested without a
 *	socket or a cluster.
 */
#ifndef	SOURCE_ELIGIBILITY_H
#define	SOURCE_ELIGIBILITY_H

#include <string>

namespace gree {
namespace flare {

struct source_binding {
	enum state {
		none = 0,		// no copy validated in this process (reads proxied)
		eligible,		// validated against `source`: local reads allowed
		revalidating,	// the source changed (or its history is in question): reads proxied
		needs_rebuild,	// confirmed different lineage/history: reads proxied, rebuild requested
	};
	state			st;
	std::string		source;			// node key the copy was validated against
	std::string		master_id;		// lineage of that validation
	std::string		source_epoch;	// history of that validation ("" = legacy peer, lineage only)
	std::string		reason;			// why the state is what it is
	unsigned long long	generation;	// bumped on every change (compare-and-set for the validator)

	source_binding(): st(none), generation(0) {}
	bool is_eligible() const { return st == eligible; }
	static const char* state_name(state s) {
		switch (s) {
		case eligible: return "eligible";
		case revalidating: return "revalidating";
		case needs_rebuild: return "needs_rebuild";
		default: return "none";
		}
	}
};

/**
 *	What one identity probe of the CURRENT master showed.
 */
struct source_probe {
	bool			complete;		// a full identity reply (else: Unknown)
	std::string		master_id;
	bool			epoch_token;	// the reply carried a source_epoch field at all
	std::string		source_epoch;
	source_probe(): complete(false), epoch_token(false) {}
};

/**
 *	The validator's decision for a binding, given the partition's current
 *	master in the accepted map and a probe of it.
 */
enum source_decision {
	decision_keep = 0,			// nothing to change
	decision_rebind,			// same lineage and history: eligible again, bound to `current`
	decision_wait_unknown,		// cannot observe: keep the copy, stay (or become) non-eligible, retry
	decision_needs_rebuild,		// confirmed different lineage or history: rebuild
};

/**
 *	Pure decision. `current` is the partition master named by the map this
 *	node accepted (empty = none).
 *	- No validated copy (none / needs_rebuild): nothing to decide here; only a
 *	  completed reconstruction binds a copy.
 *	- A copy validated without a lineage (backend without one): no identity to
 *	  compare; it follows the map (rebind), as before R3.
 *	- Probe incomplete or no master: Unknown. An eligible binding to the SAME
 *	  source stays as it is (an unobservable master is not a history change);
 *	  anything else waits non-eligible, keeping the copy.
 *	- Lineage differs: needs_rebuild.
 *	- Epochs both present: equal = same history (rebind to `current`),
 *	  different = needs_rebuild.
 *	- The binding has an epoch but the peer reports none: cannot confirm, wait.
 *	- Neither has an epoch (legacy peer, recorded as weaker): lineage only.
 */
inline source_decision decide_source(const source_binding& b, const std::string& current, const source_probe& p) {
	if (b.st == source_binding::none || b.st == source_binding::needs_rebuild) {
		return decision_keep;
	}
	const bool same_source = !current.empty() && current == b.source;
	// A copy validated WITHOUT a lineage (a backend that has none, e.g. tch):
	// there is no identity to compare — the previous behavior, explicitly.
	if (b.master_id.empty()) {
		if (current.empty()) return decision_wait_unknown;
		return (b.st == source_binding::eligible && same_source) ? decision_keep : decision_rebind;
	}
	if (current.empty() || !p.complete || p.master_id.empty()) {
		return (b.st == source_binding::eligible && same_source) ? decision_keep : decision_wait_unknown;
	}
	if (p.master_id != b.master_id) {
		return decision_needs_rebuild;
	}
	if (!b.source_epoch.empty()) {
		if (!p.epoch_token || p.source_epoch.empty()) {
			return (b.st == source_binding::eligible && same_source) ? decision_keep : decision_wait_unknown;
		}
		if (p.source_epoch != b.source_epoch) {
			return decision_needs_rebuild;
		}
		return (b.st == source_binding::eligible && same_source) ? decision_keep : decision_rebind;
	}
	// legacy: the copy was validated without an epoch
	if (p.epoch_token && !p.source_epoch.empty()) {
		// the peer now has a history the copy was never compared with
		return decision_wait_unknown;
	}
	return (b.st == source_binding::eligible && same_source) ? decision_keep : decision_rebind;
}

}	// namespace flare
}	// namespace gree

#endif	// SOURCE_ELIGIBILITY_H
