/**
 *	op_proxy_write.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PROXY_WRITE_H
#define	OP_PROXY_WRITE_H

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (proxy_write)
 */
class op_proxy_write : public op {
protected:
	cluster*					_cluster;
	storage*					_storage;
	storage::entry		_entry;

public:
	op_proxy_write(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual ~op_proxy_write();

	virtual int run_client(storage::entry& e);

	storage::entry& get_entry() { return this->_entry; };

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(storage::entry& e);
	virtual int _parse_text_client_parameters(storage::entry& e);

	inline bool _is_sync(uint32_t option, cluster::replication cluster_option) {
		if (option & storage::option_sync) {
			return true;
		} else if (option & storage::option_async) {
			return false;
		} else if (cluster_option == cluster::replication_sync) {
			return true;
		}
		return false;
	};
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PROXY_WRITE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
