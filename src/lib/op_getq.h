/**
 *	op_getq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_GETQ_H
#define	OP_GETQ_H

#include "op_getq.h"

namespace gree {
namespace flare {

/**
 *	opcode class (GetQ)
 */
class op_getq : public op_get {
public:
	op_getq(shared_connection c, cluster* cl, storage* st):
		op_get(c, "get", binary_header::opcode_getq, cl, st) {
	}

	virtual ~op_getq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_GETQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
