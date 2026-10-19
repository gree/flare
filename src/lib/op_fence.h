/**
 *	op_fence.h
 *
 *	Operator-only planned-eviction write fence (write_fence.h).
 *
 *	syntax: fence arm <token> <ttl_sec>     arm, or re-arm with the same token
 *	        fence release <token>           release (no-op when not armed)
 *	        fence status
 *	reply:  STAT fence_active <0|1>
 *	        STAT fence_token <token|->
 *	        STAT fence_remaining_sec <n>
 *	        STAT fence_in_flight <n>
 *	        END
 *	        or SERVER_ERROR <reason> (another token holds the fence, bad args)
 */
#ifndef	OP_FENCE_H
#define	OP_FENCE_H

#include "op.h"

using namespace std;

namespace gree {
namespace flare {

class op_fence : public op {
protected:
	string		_action;
	string		_token;
	uint32_t	_ttl;

public:
	op_fence(shared_connection c);
	virtual ~op_fence();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_FENCE_H
