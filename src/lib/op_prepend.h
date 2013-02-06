/**
 *	op_prepend.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_PREPEND_H__
#define	__OP_PREPEND_H__

#include "op_append.h"

using namespace std;
using namespace boost;

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

#endif	// __OP_PREPEND_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
