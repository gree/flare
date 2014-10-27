/**
 *	queue_proxy_write.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	QUEUE_PROXY_WRITE_H
#define	QUEUE_PROXY_WRITE_H

#include "cluster.h"
#include "storage.h"
#include "thread_queue.h"
#include "op.h"

using namespace std;

namespace gree {
namespace flare {

typedef class queue_proxy_write queue_proxy_write;
typedef boost::shared_ptr<queue_proxy_write> shared_queue_proxy_write;

/**
 *	proxy write queue class
 */
class queue_proxy_write : public thread_queue {
protected:
	cluster*								_cluster;
	storage*								_storage;
	vector<string>					_proxy;
	storage::entry					_entry;
	string									_op_ident;
	op::result							_result;
	string									_result_message;
	bool										_post_proxy;
	uint64_t								_generic_value;

public:
	static const int max_retry = 4;

	queue_proxy_write(cluster* cl, storage* st, vector<string> proxy, storage::entry entry, string op_ident);
	virtual ~queue_proxy_write();

	virtual int run(shared_connection c);
	op::result get_result() { return this->_result; };
	string get_result_message() { return this->_result_message; };
	int set_post_proxy(bool post_proxy) { this->_post_proxy = post_proxy; return 0; };
	bool is_post_proxy() { return this->_post_proxy; };
	int set_generic_value(uint64_t generic_value) { this->_generic_value = generic_value; return 0; };
	uint64_t get_generic_value() { return this->_generic_value; };
	string get_op_ident() { return this->_op_ident; };
	storage::entry& get_entry() { return this->_entry; };

protected:
	op_proxy_write* _get_op(string op_ident, shared_connection c);
};

}	// namespace flare
}	// namespace gree

#endif	// QUEUE_PROXY_WRITE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
