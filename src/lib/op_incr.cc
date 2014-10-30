/**
 *	op_incr.cc
 *
 *	implementation of gree::flare::op_incr
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_incr.h"
#include "queue_proxy_write.h"
#include "binary_request_header.h"
#include "binary_response_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_incr
 */
op_incr::op_incr(shared_connection c, cluster* cl, storage* st):
		op_proxy_write(c, "incr", binary_header::opcode_increment, cl, st),
		_value(0) {
	this->_incr = true;
}

/**
 *	ctor for op_incr
 */
op_incr::op_incr(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_proxy_write(c, ident, opcode, cl, st),
		_value(0) {
	this->_incr = true;
}

/**
 *	dtor for op_incr
 */
op_incr::~op_incr() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 */
int op_incr::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	try {
		char q[BUFSIZ];

		// key
		int n = util::next_word(p, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("key not found", 0);
			throw -1;
		}
		this->_entry.key = q;
		log_debug("storing key [%s]", this->_entry.key.c_str());

		// value
		n += util::next_digit(p+n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no value found", 0);
			throw -1;
		}
		try {
			this->_value = boost::lexical_cast<uint64_t>(q);
			log_debug("storing value [%llu]", this->_value);
		} catch (boost::bad_lexical_cast e) {
			log_debug("invalid value [%s]", e.what());
			throw -1;
		}

		// option
		n += util::next_word(p+n, q, sizeof(q));
		while (q[0]) {
			storage::option r = storage::option_none;
			if (storage::option_cast(q, r) < 0) {
				log_debug("unknown option [%s] (cast failed)", q);
				throw -1;
			}
			this->_entry.option |= r;
			log_debug("storing option [%s -> %d]", q, r);

			n += util::next_word(p+n, q, sizeof(q));
		}
	} catch (int e) {
		delete[] p;
		return e;
	}
	delete[] p;

	return 0;
}

int op_incr::_parse_binary_request(const binary_request_header& header, const char* body) {
	if (header.get_extras_length() == _binary_request_required_extras_length
			&& this->_entry.parse(header, body) == 0) {
		// Specifications require the extras to be exactly 20 bytes
		this->_value = ntohll(*reinterpret_cast<const uint64_t*>(body));
		uint32_t expire = *reinterpret_cast<const uint32_t*>(body + 2 * sizeof(uint64_t)); // 3rd position in header
		if (expire != _binary_request_expire_magic) {
			// Value will be inserted in DB if it does not exist initially
			// NOTE: Although we do parse the parameters, they are currently ignored and no key will be inserted
			uint64_t initial = ntohll(*reinterpret_cast<const uint64_t*>(body + sizeof(uint64_t))); // 2nd position in header
			expire = ntohl(expire);
			this->_entry.expire = util::realtime(expire);
			std::ostringstream initial_os;
			initial_os << initial;
			const std::string& initial_str = initial_os.str();
			this->_entry.size = initial_str.size();
			shared_byte data(new uint8_t[this->_entry.size]);
			memcpy(data.get(), initial_str.data(), this->_entry.size);
			this->_entry.data = data;
		}
		return 0;
	}
	return -1;
}

int op_incr::_run_server() {
	// pre-proxy (proxy if node is not master in request-partition)
	shared_queue_proxy_write q;
	cluster::proxy_request r_proxy = this->_cluster->pre_proxy_write(this, q, this->_value);
	if (r_proxy == cluster::proxy_request_complete) {
		if (this->_entry.option & storage::option_noreply) {
			// we should not access variable "q"
			return 0;
		} else if (q->is_success() == false) {
			return this->_send_result(result_server_error, "proxy error");
		} else {
			if (q->get_result() == result_stored) {
				return this->_connection->write(q->get_result_message().c_str(), q->get_result_message().size());
			} else {
				return this->_send_result(q->get_result(), q->get_result_message().c_str());
			}
		}
	} else if (r_proxy == cluster::proxy_request_error_enqueue) {
		return this->_send_result(result_server_error, "proxy failure");
	} else if (r_proxy == cluster::proxy_request_error_partition) {
		return this->_send_result(result_server_error, "no partition available");
	}

	// storage i/o
	storage::result r_storage;
	if (this->_storage->incr(this->_entry, this->_value, r_storage, this->_incr) < 0) {
		return this->_send_result(result_server_error, "i/o error");
	}

	if (r_storage == storage::result_stored) {
		if(this->_incr){
			stats_object->increment_incr_hits();
		} else {
			stats_object->increment_decr_hits();
		}
		// post-proxy (notify updates to slaves if we need)
		r_proxy = this->_cluster->post_proxy_write(this, this->_is_sync(this->_entry.option, this->_cluster->get_replication_type()));
	} else if (r_storage == storage::result_not_found) {
		if(this->_incr){
			stats_object->increment_incr_misses();
		} else {
			stats_object->increment_decr_misses();
		}
	}
	
	if ((this->_entry.option & storage::option_noreply) == 0) {
		if (r_storage == storage::result_stored && this->_entry.is_data_available()) {
			return this->_send_result(result_stored);
		} else {
			return this->_send_result(static_cast<result>(r_storage));
		}
	}

	return 0;
}

int op_incr::_run_client(storage::entry& e) {
	string proxy_ident = this->_get_proxy_ident();
	int request_len = proxy_ident.size() + e.key.size() + BUFSIZ;
	char* request = new char[request_len];
	int offset = snprintf(request, request_len, "%s%s %s %llu", proxy_ident.c_str(), this->get_ident().c_str(), e.key.c_str(), static_cast<unsigned long long>(this->_value));
	if (e.option & storage::option_noreply) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_noreply).c_str());
	}
	if (e.option & storage::option_sync) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_sync).c_str());
	}
	if (e.option & storage::option_async) {
		offset += snprintf(request+offset, request_len-offset, " %s", storage::option_cast(storage::option_async).c_str());
	}
	offset += snprintf(request+offset, request_len-offset, "%s", line_delimiter);
	if (this->_connection->write(request, offset) < 0) {
		delete[] request;
		return -1;
	}
	delete[] request;

	return 0;
}

int op_incr::_parse_text_client_parameters(storage::entry& e) {
	if (e.option & storage::option_noreply) {
		this->_result = result_none;
		return 0;
	}

	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	// skip traling ws
	int len = strlen(p);
	while (len >= 0) {
		if ((*(p+len) != '\0' && *(p+len) != '\n' && *(p+len) != ' ') || len == 0) {
			len++;
			break;
		}
		len--;
	}
	*(p+len) = '\0';
	log_debug("normalized resonse: %s", p);

	try {
		(void)boost::lexical_cast<uint64_t>(p);
		shared_byte data(new uint8_t[strlen(p)+1]);
		strcpy(reinterpret_cast<char*>(data.get()), p);
		e.data = data;
		e.size = strlen(p);
		this->_result = result_stored;
	} catch (boost::bad_lexical_cast e) {
		// then try to parse response as always
		*(p+len) = '\n'; *(p+len+1) = '\0';
		if (this->_parse_text_response(p, this->_result, this->_result_message) < 0) {
			delete[] p;
			return -1;
		}
	}
	delete[] p;

	return 0;
}

int op_incr::_send_text_result(result r, const char* message) {
	if (r != result_stored) {
		return op::_send_text_result(r, message);
	} else {
		char response[BUFSIZ];
		int response_len = this->_entry.size;
		memcpy(response, this->_entry.data.get(), this->_entry.size);
		response_len += snprintf(response+response_len, sizeof(response)-response_len, "%s", line_delimiter);
		return this->_connection->write(response, response_len);
	}
}

int op_incr::_send_binary_result(result r, const char* message) {
	if (r != result_stored) {
		return op::_send_binary_result(r, message);
	} else if (!_quiet) {
		binary_response_header header(this->_opcode);
		uint32_t total_body_length = sizeof(uint64_t);
		header.set_total_body_length(total_body_length);
		std::istringstream is_value(std::string(reinterpret_cast<const char*>(this->_entry.data.get()), this->_entry.size));
		uint64_t value = 0;
		if (!(is_value >> value).fail()) {
			value = htonll(value);
		}
		return op::_send_binary_response(header, reinterpret_cast<const char*>(&value));
	}
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
