/**
 *	op_prependq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_PREPENDQ_H__
#define	__OP_PREPENDQ_H__

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

#endif	// __OP_PREPENDQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
