/**
 *	op_show_index.h
 *
 *	@author	Takanori Sejima <takanori.sejima@gmail.com>
 *
 *	$Id$
 */
#ifndef __OP_SHOW_INDEX_H__
#define __OP_SHOW_INDEX_H__

#include <sstream>

#include "op_show.h"

namespace gree {
namespace flare {

/**
 *	opcode class (show)
 */
class op_show_index : public op_show {
protected:

public:
	op_show_index(shared_connection c);
	virtual ~op_show_index();

protected:
	virtual int _parse_server_parameter();
	virtual int _run_server();

	virtual int _send_show_variables();
};

}	// namespace flare
}	// namespace gree

#endif // __OP_SHOW_INDEX_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
