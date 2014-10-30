/**
 *	queue_proxy_read.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	QUEUE_PROXY_READ_H
#define	QUEUE_PROXY_READ_H

#include <list>

#include "cluster.h"
#include "storage.h"
#include "thread_queue.h"
#include "op.h"

using namespace std;

namespace gree {
namespace flare {

typedef class queue_proxy_read queue_proxy_read;
typedef boost::shared_ptr<queue_proxy_read> shared_queue_proxy_read;

/**
 *	proxy read queue class
 */
class queue_proxy_read : public thread_queue {
protected:
	cluster*								_cluster;
	storage*								_storage;
	vector<string>					_proxy;
	storage::entry					_entry;
	list<storage::entry>		_entry_list;
	void*										_parameter;
	string									_op_ident;
	op::result							_result;
	string									_result_message;

public:
	static const int max_retry = 4;

	queue_proxy_read(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, void* parameter, string op_ident);
	virtual ~queue_proxy_read();

	virtual int run(shared_connection c);
	op::result get_result() { return this->_result; };
	string get_result_message() { return this->_result_message; };
	storage::entry& get_entry() { return this->_entry; };
	list<storage::entry>& get_entry_list() { return this->_entry_list; };

protected:
	op_proxy_read* _get_op(string op_ident, shared_connection c);
};

}	// namespace flare
}	// namespace gree

#endif	// QUEUE_PROXY_READ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
