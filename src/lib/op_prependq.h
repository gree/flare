/**
 *	op_prependq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_PREPENDQ_H
#define	OP_PREPENDQ_H

#include "op_prepend.h"

namespace gree {
namespace flare {

/**
 *	opcode class (PrependQ)
 */
class op_prependq : public op_prepend {
public:
	op_prependq(shared_connection c, cluster* cl, storage* st):
		op_prepend(c, "prepend", binary_header::opcode_prependq, cl, st) {
	}

	virtual ~op_prependq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PREPENDQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
