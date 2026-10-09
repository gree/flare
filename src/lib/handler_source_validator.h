/**
 *	handler_source_validator.h
 *
 *	R3: re-validates the source a slave's copy is eligible for. Woken when
 *	the node accepts a map that changes its partition's master (the map
 *	acceptance has already withdrawn local reads), and every
 *	`source_check_interval_ms` to notice a history change of the SAME master
 *	(same name, new source epoch). The decision itself is the pure
 *	decide_source() in source_eligibility.h.
 */
#ifndef	HANDLER_SOURCE_VALIDATOR_H
#define	HANDLER_SOURCE_VALIDATOR_H

#include "thread_handler.h"
#include "cluster.h"
#include "source_eligibility.h"

namespace gree {
namespace flare {

class handler_source_validator : public thread_handler {
protected:
	cluster*		_cluster;

public:
	handler_source_validator(shared_thread t, cluster* cl);
	virtual ~handler_source_validator();

	virtual int run();

	// One identity probe of `node_key` (bounded: 3 s connect, 5 s per read,
	// 8 s in total). An incomplete reply leaves `p.complete` false.
	static void probe(const string& node_key, cluster* cl, source_probe& p);

protected:
	void _check_once();
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_SOURCE_VALIDATOR_H
