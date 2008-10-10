/**
 *	op_version.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_VERSION_H__
#define	__OP_VERSION_H__

#include "op.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (version)
 */
class op_version: public op {
protected:

public:
	op_version(shared_connection c);
	virtual ~op_version();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_VERSION_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
