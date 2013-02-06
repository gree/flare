/**
 *	op_getq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_GETQ_H__
#define	__OP_GETQ_H__

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

#endif	// __OP_GETQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
