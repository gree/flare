/**
 *	op_replace.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_REPLACE_H__
#define	__OP_REPLACE_H__

#include "op_set.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (replace)
 */
class op_replace : public op_set {
public:
	op_replace(shared_connection c, cluster* cl, storage* st);
	virtual ~op_replace();

protected:
	op_replace(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_REPLACE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
