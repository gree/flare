/**
 *	op_history.h
 *
 *	History continuation across an ordered handover
 *	(docs/design-handover-history-continuation.md, 6th revision). Sent by
 *	the operator only; nothing active changes until the commit, which flared
 *	makes itself when it accepts the map naming the prepared successor
 *	(replica) or is promoted (successor).
 *
 *	syntax: history promote_prepare <hid> <partition> <successor> <deadline_ms>
 *	        history prepare <hid> <partition> <successor> <from_epoch> <to_epoch> <seq> <master_id> <deadline_ms> <incarnation>
 *	        history arm <hid> <map_version>     (bind to the exact V2 map)
 *	        history discard <hid>
 *	reply:  STAT history_result <prepared|already|discarded|refused:...|failed:...>
 *	        [STAT history_to_epoch / history_seq / history_master_id] (promote_prepare)
 *	        END
 */
#ifndef	OP_HISTORY_H
#define	OP_HISTORY_H

#include <vector>

#include "op.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

class op_history : public op {
protected:
	storage*	_storage;
	vector<string>	_args;

public:
	op_history(shared_connection c, storage* st);
	virtual ~op_history();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_HISTORY_H
