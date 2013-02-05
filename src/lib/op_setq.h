/**
 *	op_setq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_SETQ_H__
#define	__OP_SETQ_H__

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

#endif	// __OP_SETQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
