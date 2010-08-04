/**
 *	op_proxy_read.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_PROXY_READ_H__
#define	__OP_PROXY_READ_H__

#include <list>

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (proxy_read)
 */
class op_proxy_read : public op {
protected:
	cluster*							_cluster;
	storage*							_storage;
	list<storage::entry>	_entry_list;
	void*									_parameter;
	bool									_is_multiple_response;

public:
	op_proxy_read(shared_connection c, string ident, cluster* cl, storage* st);
	virtual ~op_proxy_read();

	bool is_multiple_response() { return this->_is_multiple_response; };

	virtual int run_client(storage::entry& e, void* parameter);
	virtual int run_client(list<storage::entry>& entry_list, void* parameter);

	list<storage::entry>& get_entry_list() { return this->_entry_list; };

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(storage::entry& e, void* parameter);
	virtual int _run_client(list<storage::entry>& e, void* parameter);
	virtual int _parse_client_parameter(storage::entry& e);
	virtual int _parse_client_parameter(list<storage::entry>& e);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_PROXY_READ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
