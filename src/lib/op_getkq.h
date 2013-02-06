/**
 *	op_getkq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_GETKQ_H__
#define	__OP_GETKQ_H__

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

#endif	// __OP_GETKQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
