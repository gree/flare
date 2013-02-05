/**
 *	op_addq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_ADDQ_H__
#define	__OP_ADDQ_H__

#include "op_add.h"

namespace gree {
namespace flare {

/**
 *	opcode class (AddQ)
 */
class op_addq : public op_add {
public:
	op_addq(shared_connection c, cluster* cl, storage* st):
		op_add(c, "add", binary_header::opcode_addq, cl, st) {
	}

	virtual ~op_addq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_ADDQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
