/**
 *	handler_authority.h
 *
 *	C' (docs §13): the master's authority thread. One request round per
 *	renew interval and partition: the send point is taken on the node's own
 *	clock before any request goes out (write_promise::begin_round), a
 *	`authority promise` goes to EVERY successor, and only when all answered
 *	PROMISED the grant is applied (deadline = send point + ttl).
 */
#ifndef	HANDLER_AUTHORITY_H
#define	HANDLER_AUTHORITY_H

#include "app.h"
#include "cluster.h"
#include "write_promise.h"

#include <map>

namespace gree {
namespace flare {

class handler_authority : public thread_handler {
protected:
	cluster*	_cluster;
	std::map<uint32_t, uint64_t>	_last_round_ns;

public:
	handler_authority(shared_thread t, cluster* cl);
	virtual ~handler_authority();

	virtual int run();

	/** one pass over every partition whose membership is replicated; true when a round was run */
	bool run_once();
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_AUTHORITY_H
