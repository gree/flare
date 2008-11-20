/**
 *	op_append.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_APPEND_H__
#define	__OP_APPEND_H__

#include "op_set.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (append)
 */
class op_append : public op_set {
protected:

public:
	op_append(shared_connection c, cluster* cl, storage* st);
	virtual ~op_append();

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_APPEND_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
