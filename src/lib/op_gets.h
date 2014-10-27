/**
 *	op_gets.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_GETS_H
#define	OP_GETS_H

#include "op_get.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (gets)
 */
class op_gets : public op_get {
public:
	op_gets(shared_connection c, cluster* cl, storage* st);
	virtual ~op_gets();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_GETS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
