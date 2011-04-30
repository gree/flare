/**
 *	op_dump.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_DUMP_H__
#define	__OP_DUMP_H__

#include "op.h"
#include "cluster.h"
#include "storage.h"

using namespace std;
using namespace boost;

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
	int								_bwlimit;
	int								_total_written;
	struct timeval					_prior_tv;

public:
	op_dump(shared_connection c, cluster* cl, storage* st);
	virtual ~op_dump();

	virtual int run_client(int wait, int partition, int partition_size, int bwlimit = 0);

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(int wait, int partition, int partition_size, int bwlimit);
	virtual int _parse_client_parameter();
	virtual void _sleep_for_bwlimit(int bytes_written);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_DUMP_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
