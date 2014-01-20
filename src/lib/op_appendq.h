/**
 *	op_appendq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_APPENDQ_H
#define	OP_APPENDQ_H

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

#endif	// OP_APPENDQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
