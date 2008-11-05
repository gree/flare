/**
 *	op.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__OP_H__
#define	__OP_H__

#include "config.h"
#include "singleton.h"
#include "mm.h"
#include "logger.h"
#include "util.h"
#include "connection.h"
#include "thread.h"
#include "storage.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

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
	};

protected:
	shared_connection			_connection;
	shared_thread					_thread;
	string								_ident;
	vector<string>				_proxy;
	bool									_proxy_request;
	bool									_shutdown_request;
	result								_result;
	string								_result_message;

public:
	op(shared_connection c, string ident = "");
	virtual ~op();

	virtual int run_server();
	virtual int run_client();

	int set_proxy(string proxy);
	int set_thread(shared_thread t) { this->_thread = t; return 0; };
	string get_ident() { return this->_ident; };
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
	virtual int _parse_server_parameter();
	virtual int _run_server();
	virtual int _run_client();
	virtual int _parse_client_parameter();
	virtual int _parse_response(const char* p, result& r, string& r_message);

	int _send_result(result r, const char* message = NULL);
	int _send_request(const char* request);
};

}	// namespace flare
}	// namespace gree

#endif	// __OP_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
