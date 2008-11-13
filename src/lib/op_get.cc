/**
 *	op_get.cc
 *
 *	implementation of gree::flare::op_get
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_get.h"
#include "queue_proxy_read.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_get
 */
op_get::op_get(shared_connection c, cluster* cl, storage* st):
		op_proxy_read(c, "get", cl, st) {
	this->_append_version = false;
}

/**
 *	ctor for op_get
 */
op_get::op_get(shared_connection c, string ident, cluster* cl, storage* st):
		op_proxy_read(c, ident, cl, st) {
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
int op_get::_parse_server_parameter() {
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
	_delete_(p);

	if (this->_entry_list.size() == 0) {
		return -1;
	}

	return 0;
}

int op_get::_run_server() {
	map<string, shared_queue_proxy_read> q_map;
	map<string, storage::result> r_map;

	for (list<storage::entry>::iterator it = this->_entry_list.begin(); it != this->_entry_list.end(); it++) {
		shared_queue_proxy_read q;
		cluster::proxy_request r_proxy = this->_cluster->pre_proxy_read(this, *it, q);
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
			if (this->_storage->get(*it, r_storage) < 0) {
				log_warning("storage i/o error (key=%s) -> continue processing (pretending not found)", it->key.c_str());
				r_map[it->key] = storage::result_not_found;
				continue;
			}
			r_map[it->key] = r_storage;
		}
	}

	for (list<storage::entry>::iterator it = this->_entry_list.begin(); it != this->_entry_list.end(); it++) {
		char* response = NULL;
		int response_len = 0;

		if (q_map.count(it->key) > 0) {
			shared_queue_proxy_read q = q_map[it->key];
			q->sync();
			storage::entry& e = q->get_entry();
			if (e.is_data_available() == false) {
				continue;
			}
			e.response(&response, response_len, this->_append_version ? storage::response_type_gets : storage::response_type_get);
		} else if (r_map.count(it->key) == 0) {
			log_warning("result map is inconsistent (key=%s)", it->key.c_str());
			continue;
		} else if (r_map[it->key] == storage::result_not_found) {
			continue;
		} else {
			it->response(&response, response_len, this->_append_version ? storage::response_type_gets : storage::response_type_get);
		}

		this->_connection->write(response, response_len);
		_delete_(response);
	}

	this->_send_result(result_end);

	return 0;
}

int op_get::_run_client(storage::entry& e) {
	int request_len = e.key.size() + BUFSIZ;
	char* request = _new_ char[request_len];
	snprintf(request, request_len, "get %s", e.key.c_str());
	int r = this->_send_request(request);
	_delete_(request);

	return r;
}

int op_get::_run_client(list<storage::entry>& e) {
	if (e.size() == 0) {
		log_warning("passed 0 entry...", 0);
		return -1;
	}

	ostringstream s;
	s << "get";
	for (list<storage::entry>::iterator it = e.begin(); it != e.end(); it++) {
		s << " " << it->key;
	}

	return this->_send_request(s.str().c_str());
}

int op_get::_parse_client_parameter(storage::entry& e) {
	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}

		if (strcmp(p, "END\n") == 0) {
			_delete_(p);
			return 0;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "VALUE") != 0) {
			log_debug("invalid token (q=%s)", q);
			_delete_(p);
			return -1;
		}

		storage::entry e_tmp;
		if (e_tmp.parse(p+n, storage::parse_type_get) < 0) {
			_delete_(p);
			return -1;
		}
		_delete_(p);

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
		_delete_(p);
		e.data = data;
		log_debug("storing data [%d bytes]", e.size);
	}

	return 0;
}

int op_get::_parse_client_parameter(list<storage::entry>& e) {
	list<storage::entry>::iterator it = e.begin();

	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			return -1;
		}

		if (strcmp(p, "END\n") == 0) {
			_delete_(p);
			break;
		}

		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "VALUE") != 0) {
			log_debug("invalid token (q=%s)", q);
			_delete_(p);
			return -1;
		}

		storage::entry e_tmp;
		if (e_tmp.parse(p+n, storage::parse_type_get) < 0) {
			_delete_(p);
			return -1;
		}
		_delete_(p);

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
		_delete_(p);
		it->data = data;
		log_debug("storing data [%d bytes]", it->size);
	}

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
