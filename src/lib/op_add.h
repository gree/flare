/**
 *	op_add.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_ADD_H__
#define	__OP_ADD_H__

#include "op_set.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (add)
 */
class op_add : public op_set {
protected:

public:
	op_add(shared_connection c, cluster* cl, storage* st);
	virtual ~op_add();

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_ADD_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
