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
 *	test_binary_header.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "connection_iostream.h"

#include <binary_request_header.h>
#include <binary_response_header.h>

#include <stdio.h>

using namespace gree::flare;

namespace test_binary_header
{
	void setup() { }

	void test_request_header_size() {
		binary_request_header header(binary_header::opcode_noop);
		cut_assert_equal_int(24, header.get_raw_size());
	}

	void test_response_header_size() {
		binary_response_header header(binary_header::opcode_noop);
		cut_assert_equal_int(24, header.get_raw_size());
	}

	void test_request_header_endianness() {
		binary_request_header reference_header(binary_header::opcode_tap_delete);	// 0x42
		reference_header.set_key_length(0x0420);
		reference_header.set_extras_length(0x10);
		reference_header.set_data_type(0x00);
		reference_header.set_vbucket_id(0x0420);
		reference_header.set_total_body_length(0x01020304);
		reference_header.set_opaque(0x0204080F);
		reference_header.set_cas(0x1020304050607080LLU);
		// Test copy constructor
		binary_request_header test_header = reference_header;
		cut_assert_equal_memory(reference_header.get_raw_data(), reference_header.get_raw_size(),
				test_header.get_raw_data(), test_header.get_raw_size());
		// Check endianness
		int8_t big_endian_blob[24] = {
			'\x80',																									// magic
			'\x42',																									// opcode
			'\x04','\x20',																					// key_length
			'\x10',																									// extras_length
			'\x00', 																								// data_type
			'\x04','\x20',																					// vbucket_id
			'\x01','\x02','\x03','\x04',														// total_body_length
			'\x02','\x04','\x08','\x0F',														// opaque
			'\x10','\x20','\x30','\x40','\x50','\x60','\x70','\x80'	// cas
		};
		cut_assert_equal_memory(&big_endian_blob, sizeof(big_endian_blob),
				test_header.get_raw_data(), test_header.get_raw_size());
	}
	
	void test_request_header_decoding() {
		int8_t network_header[24] = {
			'\x80',																									// magic
			'\x42',																									// opcode
			'\x04','\x20',																					// key_length
			'\x10',																									// extras_length
			'\x00', 																								// data_type
			'\x04','\x20',																					// vbucket_id
			'\x01','\x02','\x03','\x04',														// total_body_length
			'\x02','\x04','\x08','\x0F',														// opaque
			'\x10','\x20','\x30','\x40','\x50','\x60','\x70','\x80'	// cas
		};
		shared_connection c(new connection_sstream(std::string(reinterpret_cast<char*>(&network_header), sizeof(network_header))));
		// Decode
		const binary_request_header header(c);
		// Check
		cut_assert_equal_int(0x42, header.get_opcode());
		cut_assert_equal_int(0x0420, header.get_key_length());
		cut_assert_equal_int(0x10, header.get_extras_length());
		cut_assert_equal_int(0x00, header.get_data_type());
		cut_assert_equal_int(0x0420, header.get_vbucket_id());
		cut_assert_equal_int(0x01020304, header.get_total_body_length());
		cut_assert_equal_int(0x0204080F, header.get_opaque());
		cut_assert_equal_int(0x1020304050607080LLU, header.get_cas());
		// Reencode
		header.push_back(c);
		// Check
		char* encoded;
		c->readsize(24, &encoded);
		cut_assert_equal_memory(&network_header, 24, encoded, 24);
		delete[] encoded;
	}

	void test_response_header_endianness() {
		binary_response_header reference_header(binary_header::opcode_tap_delete);	// 0x42
		reference_header.set_key_length(0x0420);
		reference_header.set_extras_length(0x10);
		reference_header.set_data_type(0x00);
		reference_header.set_status(0x0420);
		reference_header.set_total_body_length(0x01020304);
		reference_header.set_opaque(0x0204080F);
		reference_header.set_cas(0x1020304050607080LLU);
		// Test copy constructor
		binary_response_header test_header = reference_header;
		cut_assert_equal_memory(reference_header.get_raw_data(), reference_header.get_raw_size(),
				test_header.get_raw_data(), test_header.get_raw_size());
		// Check endianness
		int8_t big_endian_blob[24] = {
			'\x81',																									// magic
			'\x42',																									// opcode
			'\x04','\x20',																					// key_length
			'\x10',																									// extras_length
			'\x00', 																								// data_type
			'\x04','\x20',																					// status
			'\x01','\x02','\x03','\x04',														// total_body_length
			'\x02','\x04','\x08','\x0F',														// opaque
			'\x10','\x20','\x30','\x40','\x50','\x60','\x70','\x80'	// cas
		};
		cut_assert_equal_memory(&big_endian_blob, sizeof(big_endian_blob),
				test_header.get_raw_data(), test_header.get_raw_size());
	}
	
	void test_response_header_decoding() {
		int8_t network_header[24] = {
			'\x81',																									// magic
			'\x42',																									// opcode
			'\x04','\x20',																					// key_length
			'\x10',																									// extras_length
			'\x00', 																								// data_type
			'\x04','\x20',																					// status
			'\x01','\x02','\x03','\x04',														// total_body_length
			'\x02','\x04','\x08','\x0F',														// opaque
			'\x10','\x20','\x30','\x40','\x50','\x60','\x70','\x80'	// cas
		};
		shared_connection c(new connection_sstream(std::string(reinterpret_cast<char*>(&network_header), sizeof(network_header))));
		// Decode
		const binary_response_header header(c);
		// Check
		cut_assert_equal_int(0x42, header.get_opcode());
		cut_assert_equal_int(0x0420, header.get_key_length());
		cut_assert_equal_int(0x10, header.get_extras_length());
		cut_assert_equal_int(0x00, header.get_data_type());
		cut_assert_equal_int(0x0420, header.get_status());
		cut_assert_equal_int(0x01020304, header.get_total_body_length());
		cut_assert_equal_int(0x0204080F, header.get_opaque());
		cut_assert_equal_int(0x1020304050607080LLU, header.get_cas());
		// Reencode
		header.push_back(c);
		// Check
		char* encoded;
		c->readsize(24, &encoded);
		cut_assert_equal_memory(&network_header, 24, encoded, 24);
		delete[] encoded;
	}

	void test_decode_error() {
		uint8_t binary_blob[31] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25};
		shared_connection c(new connection_sstream(std::string(reinterpret_cast<char*>(&binary_blob), sizeof(binary_blob))));
		// Should fail because 0x01 != 0x80
		try {
			binary_request_header header(c);
			cut_fail("binary_request_header: expected exception did not occur");
		}	catch (...) { }
		// Check that stream got rewinded correctly
		char* buffer;
		c->readsize(1, &buffer);
		cut_assert_equal_int(1, buffer[0]);
		delete[] buffer;
	}

	void teardown() { }
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
