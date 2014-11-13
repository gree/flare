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
