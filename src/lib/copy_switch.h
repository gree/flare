/**
 *	copy_switch.h
 *
 *	Copy retention (docs/design-copy-retention.md §2, §4): the identity of a
 *	stored copy, the switch intent, and the PURE crash-recovery decision.
 *
 *	The switch replaces the live copy (data_dir/flare.rocksdb) with a verified
 *	staging copy (data_dir/staging-<attempt>) and keeps the old one as
 *	data_dir/retained-<attempt>, all siblings on one filesystem:
 *
 *	  0. the new copy is durable (DB closed, files and dir fsynced, COPY_ID)
 *	  1. switch.intent written (tmp + fsync + rename + fsync data_dir)
 *	  2. flare.rocksdb  -> retained-<attempt>   (+ fsync data_dir)
 *	  3. staging-<attempt> -> flare.rocksdb     (+ fsync data_dir)
 *	  4. the new live is opened and its COPY_ID checked
 *	  5. switch.intent removed                  (+ fsync data_dir)
 *
 *	Recovery never trusts the phase recorded in the intent: a crash between
 *	a rename and the intent update leaves a stale phase. It decides from the
 *	directories that EXIST and the COPY_ID each one holds.
 */
#ifndef	COPY_SWITCH_H
#define	COPY_SWITCH_H

#include <string>

namespace gree {
namespace flare {

struct switch_intent {
	std::string		attempt;		// attempt id (names retained-<attempt>, staging-<attempt>)
	std::string		old_id;			// copy-id of the live copy being replaced
	std::string		new_id;			// copy-id of the staging copy replacing it
	std::string		phase;			// diagnostic only
};

/**
 *	What exists on disk for one attempt: for each of live / retained-<attempt>
 *	/ staging-<attempt>, "" when the directory does not exist, otherwise the
 *	COPY_ID it holds ("?" when the directory exists but its COPY_ID is
 *	unreadable).
 */
struct switch_observation {
	std::string		live;
	std::string		retained;
	std::string		staging;
};

enum switch_recovery {
	recovery_abort_attempt = 0,	// nothing was switched: drop the intent (the attempt is abandoned)
	recovery_rollback,			// old copy moved aside, new one not in place: move the old copy back
	recovery_roll_forward,		// new copy in place, old one retained: finish (open, check, drop the intent)
	recovery_stop,				// inconsistent: stop and notify, touch nothing
};

inline const char* switch_recovery_name(switch_recovery r) {
	switch (r) {
	case recovery_abort_attempt: return "abort the attempt (nothing was switched)";
	case recovery_rollback: return "roll back (move the retained old copy back to live)";
	case recovery_roll_forward: return "roll forward (the new copy is live; finish the switch)";
	default: return "STOP (inconsistent state: nothing is touched)";
	}
}

/**
 *	The recovery table (design §4.2). `why` explains the decision.
 */
inline switch_recovery decide_switch_recovery(const switch_intent& in, const switch_observation& o, std::string& why) {
	if (in.old_id.empty() || in.new_id.empty() || in.old_id == in.new_id) {
		why = "the intent does not name two distinct copies";
		return recovery_stop;
	}
	const bool live_old = o.live == in.old_id;
	const bool live_new = o.live == in.new_id;
	const bool live_none = o.live.empty();
	const bool ret_old = o.retained == in.old_id;
	const bool ret_none = o.retained.empty();
	const bool stg_new = o.staging == in.new_id;
	const bool stg_none = o.staging.empty();

	if (live_old && ret_none && (stg_new || stg_none)) {
		why = "the live copy is still the old one and nothing was moved aside";
		return recovery_abort_attempt;
	}
	if (live_none && ret_old && stg_new) {
		why = "the old copy was moved aside but the new one is not in place";
		return recovery_rollback;
	}
	if (live_new && ret_old && stg_none) {
		why = "the new copy is in place and the old one is retained";
		return recovery_roll_forward;
	}
	if (live_new && ret_none && stg_none) {
		why = "the new copy is live but the retained old copy is missing (it must not disappear before its deletion conditions)";
		return recovery_stop;
	}
	why = "live=" + (o.live.empty() ? std::string("(none)") : o.live)
		+ " retained=" + (o.retained.empty() ? std::string("(none)") : o.retained)
		+ " staging=" + (o.staging.empty() ? std::string("(none)") : o.staging)
		+ " does not match the intent (old " + in.old_id + ", new " + in.new_id + ")";
	return recovery_stop;
}

}	// namespace flare
}	// namespace gree

#endif	// COPY_SWITCH_H
