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
 *	mock_op_proxy_write.h
 *
 *	@author Masnaori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 */

#ifndef MOCK_OP_PROXY_WRITE_H
#define MOCK_OP_PROXY_WRITE_H

#include "op_proxy_write.h"
#include "storage.h"

namespace gree {
namespace flare {

class mock_op_proxy_write : public op_proxy_write {
public:
	mock_op_proxy_write(shared_connection c, cluster* cl, storage* st):
			op_proxy_write(c, "set", binary_header::opcode_set, cl, st) {
	};
	virtual ~mock_op_proxy_write() {};

	// helper functions
	void set_entry(storage::entry& e) { this->_entry = e; };
	int parse() {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}
		if (this->_entry.parse(p, this->get_ident() == "cas" ? storage::parse_type_cas : storage::parse_type_set) < 0) {
			delete[] p;
			return -1;
		}
		delete[] p;

		if (this->_connection->readsize(this->_entry.size + 2, &p) < 0) {
			return -1;
		}
		shared_byte data(new uint8_t[this->_entry.size]);
		memcpy(data.get(), p, this->_entry.size);
		delete[] p;
		this->_entry.data = data;
		return 0;
	};

protected:
	virtual int _parse_text_server_parameters() { return 0; };
	virtual int _parse_binary_request(const binary_request_header&, const char* body) { return 0; };
	virtual int _run_server() { return 0; };
	virtual int _run_client() { return 0; };
	virtual int _parse_text_client_parameters(storage::entry& e) { return 0; };
};

}	// namespace flare
}	// namespace gree

#endif	// MOCK_OP_PROXY_WRITE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
