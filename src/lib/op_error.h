/**
 *	op_error.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_ERROR_H
#define	OP_ERROR_H

#include "op.h"

using namespace std;

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

#endif	// OP_ERROR_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
