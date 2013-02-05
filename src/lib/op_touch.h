/**
 *	op_touch.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 */
#ifndef	__OP_TOUCH_H__
#define	__OP_TOUCH_H__

#include "op_set.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode class (touch)
 */
class op_touch : public op_set {
public:
	op_touch(shared_connection c, cluster* cl, storage* st);
	virtual ~op_touch();

protected:
	op_touch(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st);
	virtual int _parse_text_server_parameters();
	virtual int _parse_binary_request(const binary_request_header&, const char* body);
	virtual int _run_client(storage::entry& e);

private:
	static const uint8_t _binary_request_required_extras_length = 4;
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_TOUCH_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
