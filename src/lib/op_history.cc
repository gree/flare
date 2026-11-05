/**
 *	op_history.cc
 *
 *	implementation of gree::flare::op_history (see the header)
 */
#include "op_history.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

#include <cstdlib>
#include <sstream>

namespace gree {
namespace flare {

op_history::op_history(shared_connection c, storage* st):
		op(c, "history"),
		_storage(st) {
}

op_history::~op_history() {
}

namespace {
bool u64(const string& s, uint64_t& v) {
	if (s.empty() || s.size() > 20 || s.find_first_not_of("0123456789") != string::npos) {
		return false;
	}
	v = strtoull(s.c_str(), NULL, 10);
	return true;
}
}	// anonymous namespace

int op_history::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	istringstream in(p);
	delete[] p;
	string a;
	while (in >> a) {
		this->_args.push_back(a);
	}
	if (this->_args.empty()) {
		return -1;
	}
	const string& op = this->_args[0];
	const size_t n = this->_args.size();
	if (op == "promote_prepare" && n == 5) return 0;
	if (op == "prepare" && n == 10) return 0;
	if (op == "discard" && n == 2) return 0;
	if (op == "arm" && n == 3) return 0;
	return -1;
}

int op_history::_run_server() {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = this->_storage ? dynamic_cast<storage_rocksdb*>(this->_storage) : NULL;
	if (rdb == NULL) {
		return this->_send_result(result_server_error, "not_supported");
	}
	const vector<string>& a = this->_args;
	string result;
	ostringstream extra;
	if (a[0] == "promote_prepare") {
		uint64_t partition = 0, deadline = 0;
		if (!u64(a[2], partition) || !u64(a[4], deadline)) {
			return this->_send_result(result_client_error, "bad number");
		}
		storage_rocksdb::pending_history out;
		if (rdb->history_promote_prepare(a[1], partition, a[3], deadline, out, result) == 0) {
			extra << "STAT history_from_epoch " << out.from_epoch << "\r\n"
				<< "STAT history_to_epoch " << out.to_epoch << "\r\n"
				<< "STAT history_seq " << out.seq << "\r\n"
				<< "STAT history_master_id " << out.master_id << "\r\n";
		}
	} else if (a[0] == "prepare") {
		storage_rocksdb::pending_history in;
		in.hid = a[1];
		in.successor = a[3];
		in.from_epoch = a[4];
		in.to_epoch = a[5];
		in.master_id = a[7];
		if (!u64(a[2], in.partition) || !u64(a[6], in.seq) || !u64(a[8], in.deadline_ms)) {
			return this->_send_result(result_client_error, "bad number");
		}
		rdb->history_replica_prepare(in, a[9], result);
	} else if (a[0] == "arm") {
		uint64_t v = 0;
		if (!u64(a[2], v)) {
			return this->_send_result(result_client_error, "bad number");
		}
		rdb->history_arm(a[1], v, result);
	} else {
		rdb->history_discard(a[1], "discarded by the operator", result);
	}
	string line = "STAT history_result " + result + "\r\n" + extra.str();
	this->_connection->write(line.c_str(), line.size());
	return this->_send_result(result_end);
#else
	(void)this->_storage;
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

}	// namespace flare
}	// namespace gree
