/**
 *	op.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_H
#define	OP_H

#include "config.h"
#include "singleton.h"
#include "logger.h"
#include "util.h"
#include "connection.h"
#include "thread.h"
#include "storage.h"
#include "binary_header.h"

using namespace std;

namespace gree {
namespace flare {

// Forward declaration
class binary_response_header;

/**
 *	opcode base class
 */
class op {
public:
	enum									result {
		result_error					= -3,
		result_client_error		= -2,
		result_server_error		= -1,

		result_none						= 0,
		result_ok,
		result_end,

		// followings are compatible w/ storage::result
		result_stored					= 16,
		result_not_stored,
		result_exists,
		result_not_found,
		result_deleted,
		result_found,
		result_touched,
	};

	enum protocol {
		text,
		binary,
	};

protected:
	shared_connection						_connection;
	protocol										_protocol;
	shared_thread								_thread;
	bool												_thread_available;
	const string								_ident;
	const binary_header::opcode	_opcode;
	const bool									_quiet;
	vector<string>							_proxy;
	bool												_proxy_request;
	bool												_shutdown_request;
	result											_result;
	string											_result_message;

public:
	op(shared_connection c, string ident, binary_header::opcode opcode = binary_header::opcode_noop);
	virtual ~op();

	virtual int run_server();
	virtual int run_client();

	void set_protocol(op::protocol protocol) { _protocol = protocol; }
	int set_thread(shared_thread t) { this->_thread = t; this->_thread_available = true; return 0; };
	vector<string> get_proxy() { return this->_proxy; };
	int set_proxy(string proxy);
	int set_proxy(vector<string> proxy) { this->_proxy = proxy; return 0; };
	inline string get_ident() { return this->_ident; };
	int is_proxy_request() { return this->_proxy_request; };
	bool is_shutdown_request() { return this->_shutdown_request; };
	result get_result() { return this->_result; };
	string get_result_message() { return this->_result_message; };

	static inline int result_cast(string s, result& r) {
		if (s == "") {
			r = result_none;
		} else if (s == "OK") {
			r = result_ok;
		} else if (s == "END") {
			r = result_end;
		} else if (s == "STORED") {
			r = result_stored;
		} else if (s == "NOT_STORED") {
			r = result_not_stored;
		} else if (s == "EXISTS") {
			r = result_exists;
		} else if (s == "NOT_FOUND") {
			r = result_not_found;
		} else if (s == "DELETED") {
			r = result_deleted;
		} else if (s == "FOUND") {
			r = result_found;
		} else if (s == "TOUCHED") {
			r = result_touched;
		} else if (s == "ERROR") {
			r = result_error;
		} else if (s == "CLIENT_ERROR") {
			r = result_client_error;
		} else if (s == "SERVER_ERROR") {
			r = result_server_error;
		} else {
			return -1;
		}
		return 0;
	};

	static inline string result_cast(result r) {
		switch (r) {
		case result_none:
			return "";
		case result_ok:
			return "OK";
		case result_end:
			return "END";
		case result_stored:
			return "STORED";
		case result_not_stored:
			return "NOT_STORED";
		case result_exists:
			return "EXISTS";
		case result_not_found:
			return "NOT_FOUND";
		case result_deleted:
			return "DELETED";
		case result_found:
			return "FOUND";
		case result_touched:
			return "TOUCHED";
		case result_error:
			return "ERROR";
		case result_client_error:
			return "CLIENT_ERROR";
		case result_server_error:
			return "SERVER_ERROR";
		}
		return "";
	};

protected:
	// Parse parameters
	virtual int _parse_text_server_parameters();
	int _parse_binary_server_parameters();
	virtual int _parse_binary_request(const binary_request_header&, const char* body);

	// Run op core
	virtual int _run_server();
	virtual int _run_client();

	// Communicate within cluster
	virtual int _parse_text_client_parameters();
	virtual int _parse_binary_client_parameters();
	virtual int _parse_text_response(const char* p, result& r, string& r_message);
	int _send_request(const char* request);
	string _get_proxy_ident();

	// Send reply back to sender
	inline int _send_result(result r, const char* message = NULL);
	virtual int _send_text_result(result r, const char* message = NULL);
	virtual int _send_binary_result(result r, const char* message = NULL);
	int _send_binary_response(const binary_response_header& header, const char* body, bool buffer = false);

private:
	inline int _parse_server_parameters();
	inline int _parse_client_parameters();
};

int op::_parse_server_parameters() {
	return _protocol == text
		? _parse_text_server_parameters()
		: _parse_binary_server_parameters();
}

int op::_parse_client_parameters() {
	return _protocol == text
		? _parse_text_client_parameters()
		: _parse_binary_client_parameters();
}

int op::_send_result(result r, const char* message) {
	return _protocol == text
		? _send_text_result(r, message)
		: _send_binary_result(r, message);
}

}	// namespace flare
}	// namespace gree

#endif	// OP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
