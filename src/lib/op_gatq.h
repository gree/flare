/**
 *	op_gatq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_GATQ_H
#define	OP_GATQ_H

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

#endif	// OP_GATQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
