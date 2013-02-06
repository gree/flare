/**
 *	op_gets.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_GETS_H__
#define	__OP_GETS_H__

#include "op_get.h"

using namespace std;
using namespace boost;

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

#endif	// __OP_GETS_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
