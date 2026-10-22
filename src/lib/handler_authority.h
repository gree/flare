/**
 *	handler_authority.h
 *
 *	C' (docs §13): the master's authority thread. One request round per
 *	renew interval and partition: the send point is taken on the node's own
 *	clock before any request goes out (write_promise::begin_round), a
 *	`authority promise` goes to EVERY successor, and only when all answered
 *	PROMISED the grant is applied (deadline = send point + ttl).
 *
 *	Each partition's round runs on its OWN short-lived thread (a successor that
 *	does not answer costs its own partition up to ttl/4, never another's), at
 *	most one round per partition at a time; the loop only dispatches.
 */
#ifndef	HANDLER_AUTHORITY_H
#define	HANDLER_AUTHORITY_H

#include "app.h"
#include "cluster.h"
#include "write_promise.h"

#include <pthread.h>
#include <map>
#include <set>

namespace gree {
namespace flare {

class handler_authority : public thread_handler {
protected:
	cluster*	_cluster;
	std::map<uint32_t, uint64_t>	_last_round_ns;
	pthread_mutex_t					_busy_mutex;
	std::set<uint32_t>				_busy;		// partitions whose round is running

public:
	handler_authority(shared_thread t, cluster* cl);
	virtual ~handler_authority();

	virtual int run();

	/** start the due rounds, each on its own thread; returns how many were started (does not wait) */
	size_t dispatch();

	/** one SYNCHRONOUS pass over every partition whose membership is replicated (the rounds run one
	    after the other); true when a round was run. For tests and as the body of a round. */
	bool run_once();

	/** one round of one partition (the body both forms share) */
	void round(const write_promise::members& m, uint64_t nonce);

private:
	/** partitions due now (renew interval over, not busy); marks them busy */
	std::vector<write_promise::members> _due();
	static void* _round_thread(void* arg);
	struct round_arg {
		handler_authority*			self;
		write_promise::members		m;
		uint64_t					nonce;
	};
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_AUTHORITY_H
