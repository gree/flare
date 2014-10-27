/**
 *	op_prepend.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PREPEND_H
#define	OP_PREPEND_H

#include "op_append.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (prepend)
 */
class op_prepend : public op_append {
public:
	op_prepend(shared_connection c, cluster* cl, storage* st);
	virtual ~op_prepend();

protected:
	op_prepend(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PREPEND_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
