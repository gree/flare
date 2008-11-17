/**
 *	op_decr.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_DECR_H__
#define	__OP_DECR_H__

#include "op_incr.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (decr)
 */
class op_decr : public op_incr {
protected:

public:
	op_decr(shared_connection c, cluster* cl, storage* st);
	virtual ~op_decr();

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_DECR_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
