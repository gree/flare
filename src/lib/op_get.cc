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
 *	op_get.cc
 *
 *	implementation of gree::flare::op_get
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_get.h"
#include "queue_proxy_read.h"
#include "binary_request_header.h"
#include "binary_response_header.h"
#include "time_watcher_scoped_observer.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_get
 */
op_get::op_get(shared_connection c, cluster* cl, storage* st):
		op_proxy_read(c, "get", binary_header::opcode_get, cl, st) {
	this->_append_version = false;
}

/**
 *	ctor for op_get
 */
op_get::op_get(shared_connection c, string ident, binary_header::opcode opcode, cluster* cl, storage* st):
		op_proxy_read(c, ident, opcode, cl, st) {
	this->_append_version = false;
}

/**
 *	dtor for op_get
 */
op_get::~op_get() {
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
int op_get::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	int n = 0;
	char q[BUFSIZ];
	for (;;) {
		n += util::next_word(p + n, q, sizeof(q));
		if (q[0] == '\0') {
			break;
		}
		storage::entry e;
		e.key = q;
		log_debug("storing key [%s]", e.key.c_str());
		this->_entry_list.push_back(e);
	}
	log_debug("found %d keys", this->_entry_list.size());
	delete[] p;

	if (this->_entry_list.size() == 0) {
		return -1;
	}

	return 0;
}

int op_get::_parse_binary_request(const binary_request_header& header, const char* body) {
	if (header.get_extras_length() == _binary_request_required_extras_length) {
		uint16_t key_length = header.get_key_length();
		if (key_length) {
			storage::entry e;
			if (e.parse(header, body) == 0) {
				this->_entry_list.push_back(e);
			}
		}
	}
	return this->_entry_list.size() > 0 ? 0 : -1;
}

int op_get::_run_server() {
	// Queries
	map<string, shared_queue_proxy_read> q_map;
	// Results
	map<string, storage::result> r_map;

	for (list<storage::entry>::iterator it = this->_entry_list.begin(); it != this->_entry_list.end(); it++) {
		stats_object->increment_cmd_get();

		shared_queue_proxy_read q;
		cluster::proxy_request r_proxy = this->_cluster->pre_proxy_read(this, *it, this->_parameter, q);
		if (r_proxy == cluster::proxy_request_complete) {
			q_map[it->key] = q;
		} else if (r_proxy == cluster::proxy_request_error_enqueue) {
			log_warning("proxy error (key=%s) -> continue processing (pretending not found)", it->key.c_str());
			r_map[it->key] = storage::result_not_found;
		} else if (r_proxy == cluster::proxy_request_error_partition) {
			log_warning("partition error (key=%s) -> continue processing (pretending not found)", it->key.c_str());
			r_map[it->key] = storage::result_not_found;
		} else {
			// storage i/o
			storage::result r_storage;
			int retcode;
			{
				storage_access_info info = { this->_thread };
				time_watcher_scoped_observer ob(info);
				retcode = this->_storage->get(*it, r_storage);
			}
			if (retcode < 0) {
				log_warning("storage i/o error (key=%s) -> continue processing (pretending not found)", it->key.c_str());
				r_map[it->key] = storage::result_not_found;
				continue;
			}
			r_map[it->key] = r_storage;
		}
	}

	for (list<storage::entry>::iterator it = this->_entry_list.begin(); it != this->_entry_list.end(); it++) {
		if (q_map.count(it->key) > 0) {
			shared_queue_proxy_read q = q_map[it->key];
			q->sync();
			storage::entry& e = q->get_entry();
			_send_entry(e);
			if (e.is_data_available()) {
				stats_object->increment_get_hits();
			} else {
				stats_object->increment_get_misses();
			}
		} else if (r_map.count(it->key) == 0) {
			log_warning("result map is inconsistent (key=%s)", it->key.c_str());
			stats_object->increment_get_misses();
		} else if (r_map[it->key] == storage::result_not_found) {
			_send_entry(*it);
			stats_object->increment_get_misses();
		} else {
			// for safety
			// op like "get key1 key1" will cause segfault
			_send_entry(*it);
			if (it->is_data_available()) {
				stats_object->increment_get_hits();
			} else {
				stats_object->increment_get_misses();
			}
		}
	}

	this->_send_result(result_end);

	return 0;
}

int op_get::_run_client(storage::entry& e, void* parameter) {
	int request_len = e.key.size() + BUFSIZ;
	char* request = new char[request_len];
	snprintf(request, request_len, "%s %s",
			_protocol == text
				? this->get_ident().c_str()
				: "gets",
			e.key.c_str());
	int r = this->_send_request(request);
	delete[] request;

	return r;
}

int op_get::_run_client(list<storage::entry>& e, void* parameter) {
	if (e.size() == 0) {
		log_warning("passed 0 entries...", 0);
		return -1;
	}

	ostringstream s;
	s << (_protocol == text ? this->get_ident() : "gets");
	for (list<storage::entry>::iterator it = e.begin(); it != e.end(); it++) {
		s << " " << it->key;
	}

	return this->_send_request(s.str().c_str());
}

int op_get::_parse_text_client_parameters(storage::entry& e) {
	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}

		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			return 0;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "VALUE") != 0) {
			log_debug("invalid token (q=%s)", q);
			delete[] p;
			return -1;
		}

		storage::entry e_tmp;
		if (e_tmp.parse(p+n, storage::parse_type_get) < 0) {
			delete[] p;
			return -1;
		}
		delete[] p;

		if (e.key != e_tmp.key) {
			log_warning("cannot found corresponding key (key=%s)", e_tmp.key.c_str());
			return -1;
		}
		e.flag = e_tmp.flag;
		e.expire = e_tmp.expire;
		e.size = e_tmp.size;
		e.version = e_tmp.version;

		// data (+2 -> "\r\n")
		if (this->_connection->readsize(e.size + 2, &p) < 0) {
			return -1;
		}
		shared_byte data(new uint8_t[e.size]);
		memcpy(data.get(), p, e.size);
		delete[] p;
		e.data = data;
		log_debug("storing data [%d bytes]", e.size);
	}

	return 0;
}

int op_get::_parse_text_client_parameters(list<storage::entry>& e) {
	list<storage::entry>::iterator it = e.begin();

	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}

		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			break;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "VALUE") != 0) {
			log_debug("invalid token (q=%s)", q);
			delete[] p;
			return -1;
		}

		storage::entry e_tmp;
		if (e_tmp.parse(p+n, storage::parse_type_get) < 0) {
			delete[] p;
			return -1;
		}
		delete[] p;

		while (it->key != e_tmp.key && it != e.end()) {
			it++;
		}
		if (it == e.end()) {
			log_warning("cannot found corresponding key (key=%s)", e_tmp.key.c_str());
			continue;
		}
		it->flag = e_tmp.flag;
		it->expire = e_tmp.expire;
		it->size = e_tmp.size;
		it->version = e_tmp.version;

		// data (+2 -> "\r\n")
		if (this->_connection->readsize(it->size + 2, &p) < 0) {
			return -1;
		}
		shared_byte data(new uint8_t[it->size]);
		memcpy(data.get(), p, it->size);
		delete[] p;
		it->data = data;
		log_debug("storing data [%d bytes]", it->size);
	}

	return 0;
}

int op_get::_send_binary_result(result r, const char* message) {
	// Sending is handled by _send_binary_entry
	if (r == result_end) {
		this->_connection->write(NULL, 0);
		return 0;
	}	else {
		return op::_send_binary_result(r, message);
	}
}

int op_get::_send_text_entry(const storage::entry& entry) {
	int return_value = 0;
	if (entry.is_data_available()) {
		char* response = NULL;
		int response_len = 0;
		entry.response(&response, response_len, this->_append_version ? storage::response_type_gets : storage::response_type_get);
		return_value = this->_connection->write(response, response_len, true);
		delete[] response;
	}
	return return_value;
}

int op_get::_send_binary_entry(const storage::entry& entry) {
	int return_value = 0;
	bool prepend_key = this->_opcode == binary_header::opcode_getk
		|| this->_opcode == binary_header::opcode_getkq;
	binary_response_header header(this->_opcode);
	if (entry.is_data_available()) {
		// Data is available: send the value normally
		char* body;
		entry.response(header, &body, prepend_key);
		return_value = _send_binary_response(header, body, true);
		delete[] body;
	} else if (!_quiet) {
		// Data is not available: prepend key if needed then send "Not found" status
		header.set_status(binary_header::status_key_not_found);
		static const std::string& not_found_message = binary_header::status_cast(binary_header::status_key_not_found);
		std::ostringstream body_os;
		if (prepend_key) {
			// Prepend key
			header.set_key_length(entry.key.size());
			header.set_total_body_length(entry.key.size() + not_found_message.size());
			body_os.write(entry.key.data(), entry.key.size());
		} else {
			header.set_total_body_length(not_found_message.size());
		}
		body_os.write(not_found_message.c_str(), not_found_message.size());
		return_value = _send_binary_response(header, body_os.str().data());
	}
	return return_value;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
