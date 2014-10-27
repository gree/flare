/**
 *	op_parser.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_PARSER_H
#define	OP_PARSER_H

#include "binary_header.h"
#include "op.h"
#include "op_add.h"
#include "op_append.h"
#include "op_cas.h"
#include "op_decr.h"
#include "op_delete.h"
#include "op_dump.h"
#include "op_dump_key.h"
#include "op_error.h"
#include "op_flush_all.h"
#include "op_get.h"
#include "op_gets.h"
#include "op_incr.h"
#include "op_keys.h"
#include "op_kill.h"
#include "op_meta.h"
#include "op_node_add.h"
#include "op_node_remove.h"
#include "op_node_role.h"
#include "op_node_state.h"
#include "op_node_sync.h"
#include "op_ping.h"
#include "op_prepend.h"
#include "op_quit.h"
#include "op_replace.h"
#include "op_set.h"
#include "op_stats.h"
#include "op_touch.h"
#include "op_gat.h"
#include "op_verbosity.h"
#include "op_version.h"

using namespace std;

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
		switch (static_cast<uint8_t>(*p)) {
		case binary_header::magic_request:
			log_debug("found binary protocol magic byte (p=%c) -> creating binary parser", *p);
			parser = static_cast<op_parser*>(new T_binary(c));
			break;
		default:
			log_debug("found text protocol magic bytes (p=%c) -> creating text parser", *p);
			parser = static_cast<op_parser*>(new T_text(c));
			break;
		}
		c->push_back(p, 1);
		delete[] p;

		if (parser != NULL) {
			op* q = parser->parse_server();
			if (q) {
				log_info("determined request [ident=%s]", q->get_ident().c_str());
			}
			delete parser;
			return q;

		} else {
			log_err("failed to get op_parser", 0);
			return NULL;
		}
	}

	virtual op* parse_server() = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// OP_PARSER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
