/**
 *	copy_protection.h
 *
 *	R3-D (SAF-10 release checklist): ONE protection rule, evaluated at the
 *	moment a replica's copy would be destroyed or replaced — right before a
 *	truncate, a snapshot swap, or a discard made to free space — against the
 *	source as it is NOW and the replica's copy as it is NOW. The operator's
 *	repair check (StatsObservation.repairSourceVerdict) decides earlier, at
 *	demotion; the copy happens later, so that decision alone cannot protect
 *	the copy (CI 37493288883: approved "rebuild source holds data", copied
 *	after release and re-seat). The rule here is the SAME rule:
 *
 *	- the local copy is known to be empty: nothing to protect;
 *	- the source cannot be read (Unknown): keep the copy, wait;
 *	- the source holds keys: proceed (the existing rule — an item count does
 *	  not tell which copy is right, so nothing stricter is invented here);
 *	- the source is EMPTY: proceed only if (a) same lineage AND same source
 *	  epoch (deleted to empty in the same history), (b) the source epoch was
 *	  advanced by a BULK rewrite (truncate / flush_all: an explicit deletion),
 *	  or (c) the replica's rebuild evidence names exactly this source's
 *	  lineage and epoch. Anything else keeps the copy: an empty copy that may
 *	  have been promoted must not replace data.
 *
 *	A decision is never cached: every destructive step evaluates it afresh.
 */
#ifndef	COPY_PROTECTION_H
#define	COPY_PROTECTION_H

#include <string>
#include <stdint.h>

namespace gree {
namespace flare {

struct copy_identity {
	bool			known;				// the item count (and identity) could be read
	uint64_t		items;
	std::string		lineage;			// rocksdb_master_id
	std::string		epoch;				// rocksdb_source_epoch
	std::string		epoch_reason;		// rocksdb_source_epoch_reason (source only)
	std::string		rebuilt_from_lineage;	// rebuild evidence (replica only)
	std::string		rebuilt_from_epoch;
	// copy retention (§9): the size of the source's live copy (rocksdb_copy_bytes),
	// else its whole data dir (data_dir_used_bytes: an upper bound)
	bool			size_known;
	uint64_t		copy_bytes;
	copy_identity(): known(false), items(0), size_known(false), copy_bytes(0) {}
};

enum copy_gate {
	gate_allow_nothing_to_protect = 0,
	gate_allow,
	gate_refuse_unknown,		// keep the copy, wait
	gate_refuse_unsafe,		// keep the copy: an empty source of another history
};

inline bool copy_gate_allows(copy_gate g) {
	return g == gate_allow_nothing_to_protect || g == gate_allow;
}

inline const char* copy_gate_name(copy_gate g) {
	switch (g) {
	case gate_allow_nothing_to_protect: return "allow (the local copy is empty)";
	case gate_allow: return "allow";
	case gate_refuse_unknown: return "REFUSE (source unknown: copy kept)";
	default: return "REFUSE (unsafe source: copy kept)";
	}
}

/**
 *	Pure decision. `local` is the replica's copy, `source` the copy that would
 *	replace it. `why` explains the decision.
 */
inline copy_gate decide_copy_gate(const copy_identity& local, const copy_identity& source, std::string& why) {
	if (local.known && local.items == 0) {
		why = "the local copy holds no keys";
		return gate_allow_nothing_to_protect;
	}
	if (!source.known) {
		why = "the source's item count and identity could not be read";
		return gate_refuse_unknown;
	}
	if (source.items > 0) {
		why = "the source holds keys";
		return gate_allow;
	}
	// the source is EMPTY
	if (source.lineage.empty() || local.lineage.empty()) {
		why = "the source holds 0 keys and its history cannot be compared with this copy (lineage unknown)";
		return gate_refuse_unsafe;
	}
	if (source.lineage != local.lineage) {
		why = "the source holds 0 keys under a different lineage (" + source.lineage + " vs this copy's " + local.lineage + ")";
		return gate_refuse_unsafe;
	}
	if (!source.epoch.empty() && source.epoch == local.epoch) {
		why = "the source holds 0 keys in the same history (" + source.epoch + "): a deletion to empty";
		return gate_allow;
	}
	if (source.epoch_reason == "bulk") {
		why = "the source holds 0 keys and its history was advanced by a bulk rewrite (an explicit deletion)";
		return gate_allow;
	}
	if (!source.epoch.empty() && local.rebuilt_from_lineage == source.lineage && local.rebuilt_from_epoch == source.epoch) {
		why = "the source holds 0 keys and this copy's rebuild evidence names exactly its history (" + source.epoch + ")";
		return gate_allow;
	}
	why = "the source holds 0 keys and its history (" + (source.epoch.empty() ? std::string("unknown") : source.epoch)
		+ ", advanced by " + (source.epoch_reason.empty() ? std::string("an unknown event") : source.epoch_reason)
		+ ") is not this copy's (" + (local.epoch.empty() ? std::string("unknown") : local.epoch)
		+ "): an empty copy that may have been promoted must not replace data";
	return gate_refuse_unsafe;
}

}	// namespace flare
}	// namespace gree

#endif	// COPY_PROTECTION_H
