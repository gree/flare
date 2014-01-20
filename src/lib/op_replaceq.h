/**
 *	op_replaceq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_REPLACEQ_H
#define	OP_REPLACEQ_H

#include "op_replace.h"

namespace gree {
namespace flare {

/**
 *	opcode class (ReplaceQ)
 */
class op_replaceq : public op_replace {
public:
	op_replaceq(shared_connection c, cluster* cl, storage* st):
		op_replace(c, "replace", binary_header::opcode_replaceq, cl, st) {
	}

	virtual ~op_replaceq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_REPLACEQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
