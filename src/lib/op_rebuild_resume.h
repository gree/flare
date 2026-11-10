/**
 *	op_rebuild_resume.h
 *
 *	Copy retention (docs/design-copy-retention.md §10): the operator resumes
 *	a PARKED (blocked) staged rebuild once a rebuild slot is free. The next
 *	attempt re-checks capacity, the source and the copy identity.
 *
 *	syntax: rebuild_resume
 *	        rebuild_resume discard <pod-uid> <copy-id> <node-map-version>
 *	reply:  STAT rebuild_resumed <1|0>   (0 = it was not parked)
 *	        STAT rebuild_discard_grant accepted | refused:<reason>   (discard form only)
 *	        END
 *
 *	The discard form is the operator's word that this node's copy is
 *	redundant (docs/spec.md): a grant bound to the pod, the copy and the node
 *	map version. Accepted, it resumes the rebuild; the rebuild discards the
 *	copy only if it still does not fit and every binding still holds. Refused,
 *	nothing changes (the rebuild stays parked). The plain form clears a grant.
 */
#ifndef	OP_REBUILD_RESUME_H
#define	OP_REBUILD_RESUME_H

#include "op.h"
#include "storage.h"
#include "cluster.h"
#include "copy_discard_grant.h"

using namespace std;

namespace gree {
namespace flare {

class op_rebuild_resume : public op {
protected:
	cluster*	_cluster;
	storage*	_storage;
	bool		_discard;
	discard_grant	_grant;

public:
	op_rebuild_resume(shared_connection c, cluster* cl, storage* st);
	virtual ~op_rebuild_resume();
	// the facts the grant is checked against, read now (cl may be NULL = role unknown)
	static discard_grant_facts gather_facts(cluster* cl, storage* st);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REBUILD_RESUME_H
