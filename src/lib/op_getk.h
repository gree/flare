/**
 *	op_getk.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */
#ifndef	OP_GETK_H
#define	OP_GETK_H

#include "op_get.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (getk)
 */
class op_getk : public op_get {
public:
	op_getk(shared_connection c, cluster* cl, storage* st);
	virtual ~op_getk();

protected:
	op_getk(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_GETK_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
