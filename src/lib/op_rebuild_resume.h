/**
 *	op_rebuild_resume.h
 *
 *	Copy retention (docs/design-copy-retention.md §10): the operator resumes
 *	a PARKED (blocked) staged rebuild once a rebuild slot is free. The next
 *	attempt re-checks capacity, the source and the copy identity.
 *
 *	syntax: rebuild_resume
 *	reply:  STAT rebuild_resumed <1|0>   (0 = it was not parked)
 *	        END
 */
#ifndef	OP_REBUILD_RESUME_H
#define	OP_REBUILD_RESUME_H

#include "op.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

class op_rebuild_resume : public op {
protected:
	storage*	_storage;

public:
	op_rebuild_resume(shared_connection c, storage* st);
	virtual ~op_rebuild_resume();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REBUILD_RESUME_H
