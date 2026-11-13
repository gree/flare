/**
 *	copy_discard_grant.h
 *
 *	The operator's word that THIS node's copy is redundant (docs/spec.md, "A
 *	redundant copy is discarded on the operator's word"). PURE rules (unit
 *	tested): a grant is bound to the pod (uid), the copy (id) and the cluster
 *	state (node map version), and is accepted only on a node that is neither a
 *	master nor an Active slave, whose rebuild is parked for room. flared checks
 *	every binding twice: when the grant arrives and again right before it
 *	deletes anything.
 */
#ifndef	COPY_DISCARD_GRANT_H
#define	COPY_DISCARD_GRANT_H

#include <stdint.h>
#include <string>

namespace gree {
namespace flare {

struct discard_grant {
	std::string pod_uid;
	std::string copy_id;
	uint64_t map_version;
	discard_grant(): map_version(0) {}
	bool empty() const { return copy_id.empty(); }
};

struct discard_grant_facts {
	std::string own_pod_uid;		// FLARE_POD_UID ("" = not set)
	std::string own_copy_id;
	bool identity_consistent;
	uint64_t own_map_version;
	bool role_known;			// this node's assignment is known
	bool serving_or_master;			// master, or an Active slave
	bool quarantined;
	bool switch_unresolved;
	bool parked_no_space;			// only checked when the grant arrives
	discard_grant_facts(): identity_consistent(false), own_map_version(0), role_known(false),
		serving_or_master(true), quarantined(false), switch_unresolved(false), parked_no_space(false) {}
};

/**
 *	"" = the grant holds; otherwise the reason it is refused (the part after
 *	"refused:" in the reply).
 */
inline std::string check_discard_grant(const discard_grant& g, const discard_grant_facts& f, bool at_arrival) {
	if (f.own_pod_uid.empty()) return "pod_uid_unknown";
	if (g.pod_uid != f.own_pod_uid) return "pod_changed";
	if (g.copy_id.empty() || g.copy_id.find_first_of(" \t\r\n/") != std::string::npos) return "malformed";
	if (!f.identity_consistent) return "identity_inconsistent";
	if (g.copy_id != f.own_copy_id) return "copy_changed";
	if (g.map_version != f.own_map_version) return "map_changed";
	if (!f.role_known) return "role_unknown";
	if (f.serving_or_master) return "master_or_serving";
	if (f.quarantined) return "quarantined";
	if (f.switch_unresolved) return "switch_unresolved";
	if (at_arrival && !f.parked_no_space) return "not_parked_no_space";
	return "";
}

/**
 *	After the discard the copy's room is free again: the rebuild may start only
 *	if the need fits in what is available plus the live copy's bytes. (Nothing
 *	is discarded when it would still not fit.)
 */
inline bool discard_makes_room(uint64_t need, int64_t available, uint64_t local_copy_bytes) {
	if (available < 0) return false;
	return need <= static_cast<uint64_t>(available) + local_copy_bytes;
}

}	// namespace flare
}	// namespace gree

#endif	// COPY_DISCARD_GRANT_H
