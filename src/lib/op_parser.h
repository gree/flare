/**
 *	op_parser.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_PARSER_H__
#define	__OP_PARSER_H__

#include "op.h"
#include "op_add.h"
#include "op_cas.h"
#include "op_delete.h"
#include "op_dump.h"
#include "op_error.h"
#include "op_flush_all.h"
#include "op_get.h"
#include "op_gets.h"
#include "op_kill.h"
#include "op_node_add.h"
#include "op_node_remove.h"
#include "op_node_role.h"
#include "op_node_state.h"
#include "op_node_sync.h"
#include "op_ping.h"
#include "op_quit.h"
#include "op_replace.h"
#include "op_set.h"
#include "op_stats.h"
#include "op_verbosity.h"
#include "op_version.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	opcode parser base class
 */
class op_parser {
protected:
	shared_connection		_connection;

public:
	op_parser(shared_connection c);
	virtual ~op_parser();

	template<class T_binary, class T_text> static op* parse_server(shared_connection c) {
		// read magic byte and create parser instance
		char* p;
		if (c->readsize(1, &p) <= 0) {
			log_info("failed to read magic 1 byte", 0);
			return NULL;
		}

		op_parser* parser = NULL;
		switch (*p) {
		case 0x80:
		case 0x81:
			log_debug("found binary protocol magic bytes (p=%c) -> creating binay parser", *p);
			parser = static_cast<op_parser*>(_new_ T_binary(c));
			break;
		default:
			log_debug("found text protocol magic bytes (p=%c) -> creating text parser", *p);
			parser = static_cast<op_parser*>(_new_ T_text(c));
			break;
		}
		c->push_back(p, 1);
		_delete_(p);

		op* q = parser->parse_server();
		if (q) {
			log_info("determined request [ident=%s]", q->get_ident().c_str());
		}

		if (parser != NULL) {
			_delete_(parser);
		}

		return q;
	}

	virtual op* parse_server() = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_PARSER_H_
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
