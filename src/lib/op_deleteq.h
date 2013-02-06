/**
 *	op_deleteq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_DELETEQ_H__
#define	__OP_DELETEQ_H__

#include "op_delete.h"

namespace gree {
namespace flare {

/**
 *	opcode class (DeleteQ)
 */
class op_deleteq : public op_delete {
public:
	op_deleteq(shared_connection c, cluster* cl, storage* st):
		op_delete(c, "delete", binary_header::opcode_deleteq, cl, st) {
	}

	virtual ~op_deleteq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_DELETEQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
