/**
 *	binary_request_header.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */

#ifndef __BINARY_REQUEST_HEADER_H__
#define __BINARY_REQUEST_HEADER_H__

#include "binary_network_mapping.h"

namespace gree {
namespace flare {

struct binary_request_raw_header {
	uint8_t magic;
	uint8_t opcode;
	uint16_t key_length;
	uint8_t extras_length;
	uint8_t data_type;
	uint16_t vbucket_id;
	uint32_t total_body_length;
	uint32_t opaque;
	uint64_t cas;
};

BOOST_STATIC_ASSERT(sizeof(binary_request_raw_header) == 24);

class binary_request_header:
	public network_mapping<binary_request_raw_header,
		binary_header::magic_request> {
public:
	binary_request_header(binary_header::opcode opcode):
		network_mapping<binary_request_raw_header,
		binary_header::magic_request>(opcode) {
	}

	binary_request_header(shared_connection c):
		network_mapping<binary_request_raw_header,
		binary_header::magic_request>(c) {
	}

	DEFINE_UINT8_GETTER(magic);
	DEFINE_UINT8_GETTER(opcode);
	DEFINE_UINT16_GETTER(key_length);
	DEFINE_UINT8_GETTER(extras_length);
	DEFINE_UINT8_GETTER(data_type);
	DEFINE_UINT16_GETTER(vbucket_id);
	DEFINE_UINT32_GETTER(total_body_length);
	DEFINE_UINT32_GETTER(opaque);
	DEFINE_UINT64_GETTER(cas);

	DEFINE_UINT8_SETTER(magic);
	DEFINE_UINT8_SETTER(opcode);
	DEFINE_UINT16_SETTER(key_length);
	DEFINE_UINT8_SETTER(extras_length);
	DEFINE_UINT8_SETTER(data_type);
	DEFINE_UINT16_SETTER(vbucket_id);
	DEFINE_UINT32_SETTER(total_body_length);
	DEFINE_UINT32_SETTER(opaque);
	DEFINE_UINT64_SETTER(cas);
};

} // namespace flare
} // namespace gree

#endif//__BINARY_REQUEST_HEADER_H__

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
