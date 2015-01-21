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
 *	binary_response_header.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */

#ifndef BINARY_RESPONSE_HEADER_H
#define BINARY_RESPONSE_HEADER_H

#include "binary_network_mapping.h"

namespace gree {
namespace flare {

struct binary_response_raw_header {
	uint8_t magic;
	uint8_t opcode;
	uint16_t key_length;
	uint8_t extras_length;
	uint8_t data_type;
	uint16_t status;
	uint32_t total_body_length;
	uint32_t opaque;
	uint64_t cas;
};

BOOST_STATIC_ASSERT(sizeof(binary_response_raw_header) == 24);

class binary_response_header:
	public network_mapping<binary_response_raw_header,
		binary_header::magic_response> {
public:
	binary_response_header(binary_header::opcode opcode):
		network_mapping<binary_response_raw_header,
		binary_header::magic_response>(opcode) {
	}

	binary_response_header(shared_connection c):
		network_mapping<binary_response_raw_header,
		binary_header::magic_response>(c) {
	}
	
	DEFINE_UINT8_GETTER(magic);
	DEFINE_UINT8_GETTER(opcode);
	DEFINE_UINT16_GETTER(key_length);
	DEFINE_UINT8_GETTER(extras_length);
	DEFINE_UINT8_GETTER(data_type);
	DEFINE_UINT16_GETTER(status);
	DEFINE_UINT32_GETTER(total_body_length);
	DEFINE_UINT32_GETTER(opaque);
	DEFINE_UINT64_GETTER(cas);

	DEFINE_UINT8_SETTER(magic);
	DEFINE_UINT8_SETTER(opcode);
	DEFINE_UINT16_SETTER(key_length);
	DEFINE_UINT8_SETTER(extras_length);
	DEFINE_UINT8_SETTER(data_type);
	DEFINE_UINT16_SETTER(status);
	DEFINE_UINT32_SETTER(total_body_length);
	DEFINE_UINT32_SETTER(opaque);
	DEFINE_UINT64_SETTER(cas);
};

} // namespace flare
} // namespace gree

#endif//BINARY_RESPONSE_HEADER_H

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
