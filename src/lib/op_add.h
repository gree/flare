/**
 *	op_add.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_ADD_H
#define	OP_ADD_H

#include "op_set.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (add)
 */
class op_add : public op_set {
public:
	op_add(shared_connection c, cluster* cl, storage* st);
	virtual ~op_add();

protected:
	op_add(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_ADD_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
