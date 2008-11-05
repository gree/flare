/**
 *	queue_proxy_write.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__QUEUE_PROXY_WRITE_H__
#define	__QUEUE_PROXY_WRITE_H__

#include "cluster.h"
#include "storage.h"
#include "thread_queue.h"
#include "op.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

typedef class queue_proxy_write queue_proxy_write;
typedef shared_ptr<queue_proxy_write> shared_queue_proxy_write;

/**
 *	proxy write queue class
 */
class queue_proxy_write : public thread_queue {
protected:
	cluster*								_cluster;
	storage*								_storage;
	storage::entry					_entry;
	string									_op_ident;
	op::result							_result;
	string									_result_message;

public:
	static const int max_retry = 4;

	queue_proxy_write(cluster* cl, storage* st, storage::entry entry, string op_ident);
	virtual ~queue_proxy_write();

	virtual int run(shared_connection c);
	op::result get_result() { return this->_result; };
	string get_result_message() { return this->_result_message; };

protected:
	op_set* _get_op(string op_ident, shared_connection c);
};

}	// namespace flare
}	// namespace gree

#endif	// __QUEUE_PROXY_WRITE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
