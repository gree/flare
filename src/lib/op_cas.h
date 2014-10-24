/**
 *	op_cas.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_CAS_H
#define	OP_CAS_H

#include "op_set.h"

using namespace std;

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

#endif	// OP_CAS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
