/**
 *	op_parser_binary_node.cc
 *	
 *	implementation of gree::flare::op_parser_binary_node
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "flared.h"
#include "op_parser_binary_node.h"
#include "op_stats_node.h"
#include "op_show_node.h"

#include <op_getk.h>
#include <op_getkq.h>
#include <op_getq.h>
#include <op_decrq.h>
#include <op_deleteq.h>
#include <op_appendq.h>
#include <op_quitq.h>
#include <op_incrq.h>
#include <op_setq.h>
#include <op_replaceq.h>
#include <op_flush_allq.h>
#include <op_prependq.h>
#include <op_addq.h>
#include <op_gatq.h>

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_parser_binary_node
 */
op_parser_binary_node::op_parser_binary_node(shared_connection c):
		op_parser_binary(c) {
}

/**
 *	dtor for op_parser_binary_node
 */
op_parser_binary_node::~op_parser_binary_node() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
op* op_parser_binary_node::_determine_op(const binary_request_header& header) {
	op* r = NULL;
	switch (header.get_opcode()) {
	case binary_header::opcode_get:
		r = new op_get(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_getq:
		r = new op_getq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_getk:
		r = new op_getk(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_getkq:
		r = new op_getkq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_set:
		r = new op_set(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_setq:
		r = new op_setq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_add:
		r = new op_add(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_addq:
		r = new op_addq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_replace:
		r = new op_replace(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_replaceq:
		r = new op_replaceq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_delete:
		r = new op_delete(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_deleteq:
		r = new op_deleteq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_increment:
		r = new op_incr(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_incrementq:
		r = new op_incrq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_decrement:
		r = new op_decr(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_decrementq:
		r = new op_decrq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_quit:
		r = new op_quit(this->_connection); 
		break;
	case binary_header::opcode_quitq:
		r = new op_quitq(this->_connection); 
		break;
	case binary_header::opcode_flush:
		r = new op_flush_all(this->_connection, singleton<flared>::instance().get_storage());
		break;
	case binary_header::opcode_flushq:
		r = new op_flush_allq(this->_connection, singleton<flared>::instance().get_storage());
		break;
	case binary_header::opcode_version:
		r = new op_version(this->_connection); 
		break;
	case binary_header::opcode_append:
		r = new op_append(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_appendq:
		r = new op_appendq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_prepend:
		r = new op_prepend(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_prependq:
		r = new op_prependq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage()); 
		break;
	case binary_header::opcode_touch:
		r = new op_touch(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage());
		break;
	case binary_header::opcode_gat:
		r = new op_gat(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage());
		break;
	case binary_header::opcode_gatq:
		r = new op_gatq(this->_connection, singleton<flared>::instance().get_cluster(), singleton<flared>::instance().get_storage());
		break;
	case binary_header::opcode_stat:
		r = new op_stats_node(this->_connection); 
		break;
	case binary_header::opcode_noop:
		r = new op_ping(this->_connection);
		break;
//case binary_header::opcode_verbosity:
//case binary_header::opcode_sasl_list_mechs:
//case binary_header::opcode_sasl_auth:
//case binary_header::opcode_sasl_step:
//case binary_header::opcode_r_get:
//case binary_header::opcode_r_set:
//case binary_header::opcode_r_setq:
//case binary_header::opcode_r_append:
//case binary_header::opcode_r_appendq:
//case binary_header::opcode_r_prepend:
//case binary_header::opcode_r_prependq:
//case binary_header::opcode_r_delete:
//case binary_header::opcode_r_deleteq:
//case binary_header::opcode_r_incr:
//case binary_header::opcode_r_incrq:
//case binary_header::opcode_r_decr:
//case binary_header::opcode_r_decrq:
//case binary_header::opcode_set_vbucket:
//case binary_header::opcode_getvbucket:
//case binary_header::opcode_del_vbucket:
//case binary_header::opcode_tap_connect:
//case binary_header::opcode_tap_mutation:
//case binary_header::opcode_tap_delete:
//case binary_header::opcode_tap_flush:
//case binary_header::opcode_tap_opaque:
//case binary_header::opcode_tap_vbucket_set:
//case binary_header::opcode_tap_checkpoint_start:
//case binary_header::opcode_tap_checkpoint_end:
	default:
		r = new op_error(this->_connection); 
	}
	return r;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
