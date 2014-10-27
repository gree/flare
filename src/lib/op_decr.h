/**
 *	op_decr.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_DECR_H
#define	OP_DECR_H

#include "op_incr.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (decr)
 */
class op_decr : public op_incr {
public:
	op_decr(shared_connection c, cluster* cl, storage* st);
	virtual ~op_decr();

protected:
	op_decr(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_DECR_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
