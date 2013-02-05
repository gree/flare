/**
 *	op_gatq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_GATQ_H__
#define	__OP_GATQ_H__

#include "op_gat.h"

namespace gree {
namespace flare {

/**
 *	opcode class (GatQ)
 */
class op_gatq : public op_gat {
public:
	op_gatq(shared_connection c, cluster* cl, storage* st):
		op_gat(c, "gat", binary_header::opcode_gatq, cl, st) {
	}

	virtual ~op_gatq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_GATQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
