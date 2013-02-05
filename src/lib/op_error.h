/**
 *	op_error.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_ERROR_H__
#define	__OP_ERROR_H__

#include "op.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (error)
 */
class op_error : public op {
protected:

public:
	op_error(shared_connection c);
	virtual ~op_error();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_ERROR_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
