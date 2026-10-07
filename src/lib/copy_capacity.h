/**
 *	copy_capacity.h
 *
 *	Copy retention, capacity (docs/design-copy-retention.md §9): may a staged
 *	rebuild start, and may it continue? PURE rules (unit tested).
 *
 *	The free space reported by the filesystem (statvfs; on tmpfs the smaller
 *	of that and the cgroup memory headroom) ALREADY reflects every copy on
 *	disk (live, retained, quarantine): nothing is subtracted from it again.
 *	What a rebuild adds is the staging copy (estimated by the source's copy
 *	size) plus the reserve (spec.rocksdb.rebuildReserveBytes: compaction, the
 *	WAL catch-up, quarantine). An unset reserve stops rebuilds: no default is
 *	assumed without a measurement (R7).
 */
#ifndef	COPY_CAPACITY_H
#define	COPY_CAPACITY_H

#include <stdint.h>
#include <string>
#include <sstream>

namespace gree {
namespace flare {

enum capacity_verdict {
	capacity_ok = 0,
	capacity_reserve_unset,		// rebuild_blocked=reserve_unset
	capacity_source_unknown,	// the source's copy size could not be read
	capacity_space_unknown,		// the free space could not be read
	capacity_insufficient,		// rebuild_blocked=no_space
};

inline const char* capacity_verdict_name(capacity_verdict v) {
	switch (v) {
	case capacity_ok: return "ok";
	case capacity_reserve_unset: return "reserve_unset";
	case capacity_source_unknown: return "source_size_unknown";
	case capacity_space_unknown: return "space_unknown";
	default: return "no_space";
	}
}

/**
 *	May a staged rebuild START? need = source copy bytes + reserve, which must
 *	fit in what is available now.
 */
inline capacity_verdict decide_rebuild_capacity(int64_t reserve, bool source_known, uint64_t source_bytes,
		int64_t available, uint64_t& need, std::string& why) {
	need = 0;
	std::ostringstream w;
	if (reserve < 0) {
		why = "rebuildReserveBytes is not set: staged rebuilds stop until it is";
		return capacity_reserve_unset;
	}
	if (!source_known) {
		why = "the source's copy size could not be read";
		return capacity_source_unknown;
	}
	if (available < 0) {
		why = "the free space under the data dir could not be read";
		return capacity_space_unknown;
	}
	need = source_bytes + static_cast<uint64_t>(reserve);
	w << "need " << need << " bytes (source copy " << source_bytes << " + reserve " << reserve
		<< "), available " << available;
	why = w.str();
	if (static_cast<uint64_t>(available) < need) {
		return capacity_insufficient;
	}
	return capacity_ok;
}

/**
 *	May the copy CONTINUE? It stops before the reserve is eaten into: what is
 *	still free must stay at least the reserve (unknown = stop).
 */
inline bool capacity_watch_ok(int64_t reserve, int64_t available, std::string& why) {
	std::ostringstream w;
	if (reserve < 0 || available < 0) {
		why = reserve < 0 ? "rebuildReserveBytes is not set" : "the free space could not be read";
		return false;
	}
	w << "available " << available << ", reserve " << reserve;
	why = w.str();
	return available >= reserve;
}

}	// namespace flare
}	// namespace gree

#endif	// COPY_CAPACITY_H
