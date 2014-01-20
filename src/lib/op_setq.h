/**
 *	op_setq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_SETQ_H
#define	OP_SETQ_H

#include "op_set.h"

namespace gree {
namespace flare {

/**
 *	opcode class (SetQ)
 */
class op_setq : public op_set {
public:
	op_setq(shared_connection c, cluster* cl, storage* st):
		op_set(c, "set", binary_header::opcode_setq, cl, st) {
	}

	virtual ~op_setq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_SETQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
