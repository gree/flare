/**
 *	op_verbosity.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_VERBOSITY_H
#define	OP_VERBOSITY_H

#include "op.h"
#include "storage.h"

using namespace std;

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
	virtual int _parse_text_server_parameters();
	virtual int _run_server();
	virtual int _run_client(int verbosity, storage::option option);
	virtual int _parse_text_client_parameters(storage::option option);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_VERBOSITY_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
