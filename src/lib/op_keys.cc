/**
 *	op_keys.cc
 *
 *	implementation of gree::flare::op_keys
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_keys.h"
#include "queue_proxy_read.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_keys
 */
op_keys::op_keys(shared_connection c, cluster* cl, storage* st):
		op_proxy_read(c, "keys", binary_header::opcode_noop, cl, st) {
	this->_is_multiple_response = true;
}

/**
 *	dtor for op_keys
 */
op_keys::~op_keys() {
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
int op_keys::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	int n = 0;
	char q[BUFSIZ];
	string last_parameter;
	for (;;) {
		n += util::next_word(p + n, q, sizeof(q));
		if (q[0] == '\0') {
			break;
		}
		storage::entry e;
		last_parameter = e.key = q;
		log_debug("storing key [%s]", e.key.c_str());
		this->_entry_list.push_back(e);
	}
	delete[] p;

	if (this->_entry_list.size() < 2) {
		log_debug("not enough parameters [%d]", this->_entry_list.size());
		return -1;
	}

	// remove last parameter and assume it as a limit parameter
	this->_entry_list.pop_back();
	int limit;
	try {
		limit = boost::lexical_cast<int>(last_parameter);
		if (limit <= 0) {
			log_debug("invalid limit [%d]", limit);
			return -1;
		}
		this->_parameter = reinterpret_cast<void*>(limit);
		log_debug("storing limit [%d]", limit);
	} catch (boost::bad_lexical_cast e) {
		log_debug("invalid limit [%s]", last_parameter.c_str());
		return -1;
	}

	log_debug("found %d keys", this->_entry_list.size());

	return 0;
}

int op_keys::_run_server() {
	// this->_entry_list for response
	int limit = reinterpret_cast<intptr_t>(this->_parameter);

	map<string, shared_queue_proxy_read> q_map;
	map<string, storage::result> r_map;
	map<string, vector<string> > s_map;
	vector<string> key_list;

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
			if (this->_storage->is_capable(storage::capability_prefix_search) == false) {
				return this->_send_result(result_server_error, "not available on current storage type");
			}

			// storage i/o
			vector<string> tmp_list;
			log_debug("key prefix search (key=%s, limit=%d)", it->key.c_str(), limit);
			if (this->_storage->get_key(it->key, limit, tmp_list) < 0) {
				log_warning("storage i/o error (key=%s) -> continue processing (pretending not found)", it->key.c_str());
				r_map[it->key] = storage::result_not_found;
				continue;
			} 
			log_debug("found %d key(s)", tmp_list.size());

			s_map[it->key] = tmp_list;
			r_map[it->key] = storage::result_found;
		}
	}

	for (list<storage::entry>::iterator it = this->_entry_list.begin(); it != this->_entry_list.end(); it++) {
		if (q_map.count(it->key) > 0) {
			shared_queue_proxy_read q = q_map[it->key];
			q->sync();
			list<storage::entry>& e = q->get_entry_list();

			ostringstream s;
			for (list<storage::entry>::iterator it = e.begin(); it != e.end(); it++) {
				s << "KEY " << it->key << line_delimiter;
			}
			this->_connection->write(s.str().c_str(), s.str().size(), true);
		} else if (r_map.count(it->key) == 0) {
			log_warning("result map is inconsistent (key=%s)", it->key.c_str());
			continue;
		} else if (r_map[it->key] == storage::result_not_found) {
			continue;
		} else {
			if (s_map.count(it->key) == 0) {
				log_warning("result map is inconsistent (key=%s)", it->key.c_str());
				continue;
			}
			vector<string>& e = s_map[it->key];
			ostringstream s;
			for (vector<string>::iterator it = e.begin(); it != e.end(); it++) {
				s << "KEY " << *it << line_delimiter;
			}
			this->_connection->write(s.str().c_str(), s.str().size(), true);
		}
	}

	this->_send_result(result_end);

	return 0;
}

int op_keys::_run_client(storage::entry& e, void* parameter) {
	// support multiple entries only
	return -1;
}

int op_keys::_run_client(list<storage::entry>& e, void* parameter) {
	if (e.size() == 0) {
		log_warning("passed 0 entries...", 0);
		return -1;
	}

	int limit = reinterpret_cast<intptr_t>(parameter);

	ostringstream s;
	s << this->get_ident();
	for (list<storage::entry>::iterator it = e.begin(); it != e.end(); it++) {
		s << " " << it->key;
	}
	s << " " << limit;

	return this->_send_request(s.str().c_str());
}

int op_keys::_parse_text_client_parameters(storage::entry& e) {
	// support multiple entries only
	return -1;
}

int op_keys::_parse_text_client_parameters(list<storage::entry>& e) {
	e.clear();

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
		if (strcmp(q, "KEY") != 0) {
			log_debug("invalid token (q=%s)", q);
			delete[] p;
			return -1;
		}

		storage::entry e_tmp;
		n += util::next_word(p + n, q, sizeof(q));
		if (q[0] == '\0') {
			log_debug("no key strings found", 0);
			delete[] p;
			return -1;
		}
		e_tmp.key = q;

		e.push_back(e_tmp);

		delete[] p;
	}

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
