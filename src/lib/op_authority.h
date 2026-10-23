/**
 *	op_authority.h
 *
 *	C' admin / node-to-node op (write_promise.h, docs §13). Every verb answers
 *	SERVER_ERROR <reason> when it is refused or write-authority is off.
 *
 *	node -> node (master asks each successor):
 *	  authority promise <p> <term> <gen> <ttl_ms> <nonce>      reply: PROMISED <nonce>
 *	operator -> node:
 *	  authority members <p> <term> <gen> <ttl_ms> <renew_ms> <node_key>...   (master)
 *	  authority solo <p> <term> <gen>                                         (master)
 *	  authority floor <p> <term> <gen>                                        (replica)
 *	  authority prepare <p> <intent> <term_next> <gen> <boot> <copy>          (replica)
 *	  authority commit  <p> <intent> <term_next> <gen> <boot> <copy>
 *	  authority cancel  <p> <intent> <term_next> <gen> <boot> <copy>
 *	  authority first   <p> <boot> <copy>     (a proven fresh first build: once, this incarnation)
 *	  prepare / commit / cancel are matched as one whole scope (write_promise::scope)
 *	  authority status <p>
 *	reply of everything except promise: STAT lines, END (see _run_server).
 */
#ifndef	OP_AUTHORITY_H
#define	OP_AUTHORITY_H

#include "op.h"
#include "write_promise.h"

#include <vector>

using namespace std;

namespace gree {
namespace flare {

class op_authority : public op {
protected:
	string				_action;
	uint32_t			_partition;
	uint64_t			_a, _b, _c, _d, _e;
	vector<string>		_keys;
	vector<string>		_ids;		// boot id, copy id of the receiver (prepare / commit / cancel / first)

public:
	op_authority(shared_connection c);
	virtual ~op_authority();

	/** client side of `authority promise`: true when the peer answered PROMISED <nonce> in time */
	static bool request_promise(const string& host, int port, uint32_t partition, uint64_t term, uint64_t generation,
		uint64_t ttl_ms, uint64_t nonce, int timeout_ms, string& why);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	int _send_status(uint32_t partition);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_AUTHORITY_H
