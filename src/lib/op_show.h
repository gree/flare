/**
 *	op_show.h
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *
 *	$Id$
 */
#ifndef	OP_SHOW_H
#define	OP_SHOW_H

#include <string>

#include "op.h"
#include "cluster.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (show)
 */
class op_show : public op {
protected:
	enum			show_type {
		show_type_error = -1,
		show_type_default,
		show_type_variables,
	};

	show_type	_show_type;

public:
	op_show(shared_connection c);
	virtual ~op_show();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _run_server();

	virtual int _send_show_variables();
};

}	// namespace flare
}	// namespace gree

#endif	// OP_SHOW_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
