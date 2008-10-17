/**
 *	queue_node_sync.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__QUEUE_NODE_SYNC_H__
#define	__QUEUE_NODE_SYNC_H__

#include "cluster.h"
#include "thread_queue.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

typedef class queue_node_sync queue_node_sync;
typedef shared_ptr<queue_node_sync> shared_queue_node_sync;

/**
 *	node sync queue class
 */
class queue_node_sync : public thread_queue {
protected:
	cluster*								_cluster;
	vector<cluster::node>		_node_vector;

public:
	queue_node_sync(cluster* cl);
	virtual ~queue_node_sync();

	virtual int run(shared_connection c);
};

}	// namespace flare
}	// namespace gree

#endif	// __QUEUE_NODE_SYNC_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
