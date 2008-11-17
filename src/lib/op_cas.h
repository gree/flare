/**
 *	op_cas.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_CAS_H__
#define	__OP_CAS_H__

#include "op_set.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (cas)
 */
class op_cas : public op_set {
protected:

public:
	op_cas(shared_connection c, cluster* cl, storage* st);
	virtual ~op_cas();

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_CAS_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
