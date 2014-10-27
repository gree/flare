/**
 *	op_gat.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	OP_GAT_H
#define	OP_GAT_H

#include "op_touch.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (gat)
 */
class op_gat : public op_touch {
public:
	op_gat(shared_connection c, cluster* cl, storage* st);
	virtual ~op_gat();

protected:
	op_gat(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	
	virtual int _parse_text_client_parameters(storage::entry& e);
	virtual int _send_text_result(result r, const char* message = NULL);
	virtual int _send_binary_result(result r, const char* message = NULL);
};

}	// namespace flare
}	// namespace gree

#endif	// OP_GAT_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
