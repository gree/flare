/**
 *	op_incrq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_INCRQ_H__
#define	__OP_INCRQ_H__

#include "op_incr.h"

namespace gree {
namespace flare {

/**
 *	opcode class (IncrQ)
 */
class op_incrq : public op_incr {
public:
	op_incrq(shared_connection c, cluster* cl, storage* st):
		op_incr(c, "incr", binary_header::opcode_incrementq, cl, st) {
	}

	virtual ~op_incrq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_INCRQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
