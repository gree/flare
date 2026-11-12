/**
 *	op_wal_pin.h
 *
 *	WAL retention across an ordered handover (wal_pin.h,
 *	docs/design-handover-history-continuation.md).
 *
 *	syntax: wal_pin set <hid> <seq> <deadline_ms>
 *	        wal_pin release <hid>
 *	        wal_pin release_invalid <boot_id>   (an approved release of a
 *	                                             marker that cannot be read;
 *	                                             <boot_id> must be this
 *	                                             process's reconstruction_boot_id)
 *	reply:  STAT wal_pin_result <pinned|already|released|refused:...|failed...>
 *	        END
 */
#ifndef	OP_WAL_PIN_H
#define	OP_WAL_PIN_H

#include "op.h"
#include "storage.h"

using namespace std;

namespace gree {
namespace flare {

class op_wal_pin : public op {
protected:
	storage*	_storage;
	string		_action;
	string		_arg;
	uint64_t	_seq;
	uint64_t	_deadline_ms;

public:
	op_wal_pin(shared_connection c, storage* st);
	virtual ~op_wal_pin();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_WAL_PIN_H
