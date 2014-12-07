/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *	binary_header.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */

#ifndef BINARY_HEADER_H
#define BINARY_HEADER_H

#include <string>

namespace gree {
namespace flare {

struct binary_header {
	enum magic {
		magic_request = 0x80,
		magic_response = 0x81
	};

	enum opcode {
		opcode_get = 0x00,
		opcode_set = 0x01,
		opcode_add = 0x02,
		opcode_replace = 0x03,
		opcode_delete = 0x04,
		opcode_increment = 0x05,
		opcode_decrement = 0x06,
		opcode_quit = 0x07,
		opcode_flush = 0x08,
		opcode_getq = 0x09,
		opcode_noop = 0x0a,
		opcode_version = 0x0b,
		opcode_getk = 0x0c,
		opcode_getkq = 0x0d,
		opcode_append = 0x0e,
		opcode_prepend = 0x0f,
		opcode_stat = 0x10,
		opcode_setq = 0x11,
		opcode_addq = 0x12,
		opcode_replaceq = 0x13,
		opcode_deleteq = 0x14,
		opcode_incrementq = 0x15,
		opcode_decrementq = 0x16,
		opcode_quitq = 0x17,
		opcode_flushq = 0x18,
		opcode_appendq = 0x19,
		opcode_prependq = 0x1a,
		opcode_verbosity = 0x1b,
		opcode_touch = 0x1c,
		opcode_gat = 0x1d,
		opcode_gatq = 0x1e,
		opcode_sasl_list_mechs = 0x20,
		opcode_sasl_auth = 0x21,
		opcode_sasl_step = 0x22,
		opcode_rget = 0x30,
		opcode_rset = 0x31,
		opcode_rsetq = 0x32,
		opcode_rappend = 0x33,
		opcode_rappendq = 0x34,
		opcode_rprepend = 0x35,
		opcode_rprependq = 0x36,
		opcode_rdelete = 0x37,
		opcode_rdeleteq = 0x38,
		opcode_rincr = 0x39,
		opcode_rincrq = 0x3a,
		opcode_rdecr = 0x3b,
		opcode_rdecrq = 0x3c,
		opcode_set_vbucket = 0x3d,
		opcode_get_vbucket = 0x3e,
		opcode_del_vbucket = 0x3f,
		opcode_tap_connect = 0x40,
		opcode_tap_mutation = 0x41,
		opcode_tap_delete = 0x42,
		opcode_tap_flush = 0x43,
		opcode_tap_opaque = 0x44,
		opcode_tap_vbucket_set = 0x45,
		opcode_tap_checkpoint_start = 0x46,
		opcode_tap_checkpoint_end = 0x47
	};

	static inline bool is_quiet(opcode);

	enum data_type {
		data_type_raw = 0x00
	};

	enum status {
		status_no_error = 0x0000,
		status_key_not_found = 0x0001,
		status_key_exists = 0x0002,
		status_value_too_large = 0x0003,
		status_invalid_arguments = 0x0004,
		status_item_not_stored = 0x0005,
		status_not_a_numeric_value = 0x0006,
		status_wrong_vbucket_server = 0x0007,
		status_authentication_error = 0x0008,
		status_authentication_continue = 0x0009,
		status_unknown_command = 0x0081,
		status_out_of_memory = 0x0082,
		status_not_supported = 0x0083,
		status_internal_error = 0x0084,
		status_busy = 0x0085,
		status_temporary_failure = 0x0086,
	};

	static inline const std::string& status_cast(status);
};

bool binary_header::is_quiet(opcode opcode) {
	switch(opcode) {
		case opcode_getq:
		case opcode_getkq:
		case opcode_setq:
		case opcode_addq:
		case opcode_replaceq:
		case opcode_deleteq:
		case opcode_incrementq:
		case opcode_decrementq:
		case opcode_quitq:
		case opcode_flushq:
		case opcode_appendq:
		case opcode_prependq:
		case opcode_gatq:
		case opcode_rsetq:
		case opcode_rappendq:
		case opcode_rprependq:
		case opcode_rdeleteq:
		case opcode_rincrq:
		case opcode_rdecrq:
			return true;
		default:
			return false;
	}
	return false;
}

const std::string& binary_header::status_cast(status status) {
	switch(status) {
		case status_key_not_found:
			{
				static const std::string value = "Not found";
				return value;
			}
		case status_key_exists:
			{
				static const std::string value = "Key exists";
				return value;
			}
		case status_value_too_large:
			{
				static const std::string value = "Value too large";
				return value;
			}
		case status_invalid_arguments:
			{
				static const std::string value = "Invalid arguments";
				return value;
			}
		case status_item_not_stored:
			{
				static const std::string value = "Item not stored";
				return value;
			}
		case status_not_a_numeric_value:
			{
				static const std::string value = "Not a numeric value";
				return value;
			}
		case status_wrong_vbucket_server:
			{
				static const std::string value = "Wrong vbucket server";
				return value;
			}
		case status_authentication_error:
			{
				static const std::string value = "Authentication error";
				return value;
			}
		case status_unknown_command:
			{
				static const std::string value = "Unknown command";
				return value;
			}
		case status_out_of_memory:
			{
				static const std::string value = "Out of memory";
				return value;
			}
		case status_not_supported:
			{
				static const std::string value = "Not supported";
				return value;
			}
		case status_internal_error:
			{
				static const std::string value = "Internal error";
				return value;
			}
		case status_busy:
			{
				static const std::string value = "Busy";
				return value;
			}
		case status_temporary_failure:
			{
				static const std::string value = "Temporary failure";
				return value;
			}
		case status_no_error:
		case status_authentication_continue:
		default:
			break;
	}
	static const std::string empty;
	return empty;
}

} // namespace flare
} // namespace gree

#endif//BINARY_HEADER_H

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
