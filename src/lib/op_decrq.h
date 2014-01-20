/**
 *	op_decrq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_DECRQ_H
#define	OP_DECRQ_H

#include "op_decr.h"

namespace gree {
namespace flare {

/**
 *	opcode class (DecrQ)
 */
class op_decrq : public op_decr {
public:
	op_decrq(shared_connection c, cluster* cl, storage* st):
		op_decr(c, "decr", binary_header::opcode_decrementq, cl, st) {
	}

	virtual ~op_decrq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_DECRQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
