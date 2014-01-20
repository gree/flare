/**
 *	op_quitq.h
 *
 *	@author Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_QUITQ_H
#define	OP_QUITQ_H

#include "op_quit.h"

namespace gree {
namespace flare {

/**
 *	opcode class (QuitQ)
 */
class op_quitq : public op_quit {
public:
	op_quitq(shared_connection c):
		op_quit(c, "quit", binary_header::opcode_quitq) {
	}

	virtual ~op_quitq() {
	}
};

}	// namespace flare
}	// namespace gree

#endif	// OP_QUITQ_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
