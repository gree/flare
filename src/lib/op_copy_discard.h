/**
 *	op_copy_discard.h
 *
 *	Copy retention (docs/design-copy-retention.md §7): discard ONE named copy
 *	on an explicit, one-shot approval relayed by the operator from a
 *	FlareCopyDiscardApproval.
 *
 *	syntax: copy_discard <request-id> <operation> <copy-id>
 *	reply:  STAT copy_discard_result <applied|failed|already:<state>|refused:<reason>>
 *	        END
 */
#ifndef	OP_COPY_DISCARD_H
#define	OP_COPY_DISCARD_H

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

class op_copy_discard : public op {
protected:
	cluster*	_cluster;
	storage*	_storage;
	string		_request_id;
	string		_operation;
	string		_copy_id;

public:
	op_copy_discard(shared_connection c, cluster* cl, storage* st);
	virtual ~op_copy_discard();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_COPY_DISCARD_H
