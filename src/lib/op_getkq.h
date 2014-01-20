/**
 *	op_getkq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_GETKQ_H
#define	OP_GETKQ_H

#include "op_getk.h"

namespace gree {
namespace flare {

/**
 *	opcode class (GetKQ)
 */
class op_getkq : public op_getk {
public:
	op_getkq(shared_connection c, cluster* cl, storage* st):
		op_getk(c, "get", binary_header::opcode_getkq, cl, st) {
	}

	virtual ~op_getkq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_GETKQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
