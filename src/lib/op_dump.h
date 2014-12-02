/**
 *	op_dump.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_DUMP_H
#define	OP_DUMP_H

#include "op.h"
#include "cluster.h"
#include "storage.h"
#include "bwlimitter.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (dump)
 */
class op_dump : public op {
protected:
	cluster*					_cluster;
	storage*					_storage;
	int								_wait;
	int								_partition;
	int								_partition_size;
	bwlimitter				_bwlimitter;

public:
	op_dump(shared_connection c, cluster* cl, storage* st);
	virtual ~op_dump();

	virtual int run_client(int wait, int partition, int partition_size, uint64_t bwlimit = 0);

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(int wait, int partition, int partition_size, uint64_t bwlimit);
	virtual int _parse_text_client_parameters();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_DUMP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
