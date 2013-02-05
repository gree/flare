/**
 *	op_flush_allq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_FLUSH_ALLQ_H__
#define	__OP_FLUSH_ALLQ_H__

#include "op_flush_all.h"

namespace gree {
namespace flare {

/**
 *	opcode class (FlushQ)
 */
class op_flush_allq : public op_flush_all {
public:
	op_flush_allq(shared_connection c, storage* st):
		op_flush_all(c, "flush_all", binary_header::opcode_flushq, st) {
	}

	virtual ~op_flush_allq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_FLUSH_ALLQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
