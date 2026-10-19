/**
 *	op_fence.cc
 *
 *	implementation of gree::flare::op_fence (see the header)
 */
#include "op_fence.h"
#include "write_fence.h"

namespace gree {
namespace flare {

op_fence::op_fence(shared_connection c):
		op(c, "fence"),
		_ttl(0) {
}

op_fence::~op_fence() {
}

int op_fence::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	this->_action = q;
	if (this->_action == "arm") {
		n += util::next_word(p + n, q, sizeof(q));
		this->_token = q;
		n += util::next_word(p + n, q, sizeof(q));
		try {
			this->_ttl = boost::lexical_cast<uint32_t>(q);
		} catch (boost::bad_lexical_cast&) {
			delete[] p;
			return -1;
		}
	} else if (this->_action == "release") {
		n += util::next_word(p + n, q, sizeof(q));
		this->_token = q;
	} else if (this->_action != "status") {
		delete[] p;
		return -1;
	}
	delete[] p;
	if (this->_action != "status" && this->_token.empty()) {
		return -1;
	}
	return 0;
}

int op_fence::_run_server() {
	if (this->_action == "arm") {
		string why;
		if (!write_fence::arm(this->_token, this->_ttl, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		log_notice("write fence ARMED (token=%s ttl=%u s): every new mutation is refused", this->_token.c_str(), this->_ttl);
	} else if (this->_action == "release") {
		if (!write_fence::release(this->_token)) {
			return this->_send_result(result_server_error, "fenced by another token");
		}
		log_notice("write fence released (token=%s)", this->_token.c_str());
	}
	// one consistent reading (the generation proves continuity, write_fence.h)
	const write_fence::status fs = write_fence::snapshot();
	char line[BUFSIZ];
	snprintf(line, sizeof(line), "STAT fence_active %d\r\nSTAT fence_token %s\r\nSTAT fence_remaining_sec %u\r\nSTAT fence_in_flight %llu\r\nSTAT fence_generation %llu\r\n",
		fs.active ? 1 : 0, fs.active ? fs.token.c_str() : "-", fs.remaining_sec,
		static_cast<unsigned long long>(fs.in_flight), static_cast<unsigned long long>(fs.generation));
	this->_connection->write(line, strlen(line));
	return this->_send_result(result_end);
}

}	// namespace flare
}	// namespace gree
