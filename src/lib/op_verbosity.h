/**
 *	op_verbosity.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_VERBOSITY_H__
#define	__OP_VERBOSITY_H__

#include "op.h"
#include "storage.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (verbosity)
 */
class op_verbosity : public op {
protected:
	int								_verbosity;
	int								_option;

public:
	op_verbosity(shared_connection c);
	virtual ~op_verbosity();

	virtual int run_client(int verbositfy, storage::option option);

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client(int verbosity, storage::option option);
	virtual int _parse_client_parameter(storage::option option);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_VERBOSITY_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
