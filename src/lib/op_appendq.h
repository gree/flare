/**
 *	op_appendq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_APPENDQ_H__
#define	__OP_APPENDQ_H__

#include "op_append.h"

namespace gree {
namespace flare {

/**
 *	opcode class (AppendQ)
 */
class op_appendq : public op_append {
public:
	op_appendq(shared_connection c, cluster* cl, storage* st):
		op_append(c, "append", binary_header::opcode_appendq, cl, st) {
	}

	virtual ~op_appendq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_APPENDQ_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
