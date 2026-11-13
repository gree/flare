/**
 *	op_wal_pin.cc
 *
 *	implementation of gree::flare::op_wal_pin (see the header)
 */
#include "op_wal_pin.h"
#include "app.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

#include <cstdlib>
#include <sstream>

namespace gree {
namespace flare {

op_wal_pin::op_wal_pin(shared_connection c, storage* st):
		op(c, "wal_pin"),
		_storage(st),
		_seq(0),
		_deadline_ms(0) {
}

op_wal_pin::~op_wal_pin() {
}

int op_wal_pin::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	istringstream in(p);
	delete[] p;
	string seq, deadline, extra;
	in >> this->_action >> this->_arg;
	if (this->_action == "set") {
		in >> seq >> deadline;
		char* end = NULL;
		this->_seq = strtoull(seq.c_str(), &end, 10);
		if (seq.empty() || end == NULL || *end != '\0') {
			return -1;
		}
		this->_deadline_ms = strtoull(deadline.c_str(), &end, 10);
		if (deadline.empty() || end == NULL || *end != '\0') {
			return -1;
		}
	} else if (this->_action != "release" && this->_action != "release_invalid") {
		return -1;
	}
	if (this->_arg.empty() || (in >> extra)) {
		return -1;
	}
	return 0;
}

int op_wal_pin::_run_server() {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = this->_storage ? dynamic_cast<storage_rocksdb*>(this->_storage) : NULL;
	if (rdb == NULL) {
		return this->_send_result(result_server_error, "not_supported");
	}
	string result;
	if (this->_action == "set") {
		rdb->wal_pin_set(this->_arg, this->_seq, this->_deadline_ms, result);
	} else if (this->_action == "release") {
		rdb->wal_pin_release(this->_arg, result);
	} else {
		ostringstream own;
		own << stats_object->get_reconstruction_boot_id();
		rdb->wal_pin_release_invalid(this->_arg, own.str(), result);
	}
	string line = "STAT wal_pin_result " + result + "\r\n";
	this->_connection->write(line.c_str(), line.size());
	return this->_send_result(result_end);
#else
	(void)this->_storage;
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

}	// namespace flare
}	// namespace gree
