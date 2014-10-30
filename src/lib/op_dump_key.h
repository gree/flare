/**
 *	op_dump_key.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_DUMP_KEY_H
#define	OP_DUMP_KEY_H

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (dump_key)
 */
class op_dump_key : public op {
protected:
	cluster*					_cluster;
	storage*					_storage;
	int								_partition;
	int								_partition_size;

public:
	op_dump_key(shared_connection c, cluster* cl, storage* st);
	virtual ~op_dump_key();

	virtual int run_client(int partition, int partition_size);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(int partition, int partition_size);
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_DUMP_KEY_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
