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
 *	op_stats.cc
 *
 *	implementation of gree::flare::op_stats
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "op_stats.h"
#include "binary_request_header.h"
#include "binary_response_header.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_stats
 */
op_stats::op_stats(shared_connection c):
		op(c, "stats", binary_header::opcode_stat),
		_stats_type(stats_type_default) {
}

/**
 *	dtor for op_stats
 */
op_stats::~op_stats() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
op_stats::stats_type op_stats::_parse_stats_type(const char* body) const {
	stats_type type = stats_type_default;
	if (body) {
		char word[BUFSIZ];
		int n = util::next_word(body, word, sizeof(word));
		if (word[0] == '\0') {
			type = stats_type_default;
		} else if (strcmp(word, "items") == 0) {
			type = stats_type_items;
		} else if (strcmp(word, "slabs") == 0) {
			type = stats_type_slabs;
		} else if (strcmp(word, "sizes") == 0) {
			type = stats_type_sizes;
		} else if (strcmp(word, "threads") == 0) {
			char word2[BUFSIZ];
			util::next_word(body+n, word2, sizeof(word2));
			if (word2[0] == '\0') {
				type = stats_type_threads;
			} else if (strcmp(word2, "request") == 0) {
				type = stats_type_threads_request;
			} else if (strcmp(word2, "slave") == 0) {
				type = stats_type_threads_slave;
			} else if (strcmp(word2, "queue") == 0) {
				type = stats_type_threads_queue;
			} else {
				type = stats_type_error;
			}
		} else if (strcmp(word, "nodes") == 0) {
			type = stats_type_nodes;
		} else {
			type = stats_type_error;
		}
	}
	return type;
}

int op_stats::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	this->_stats_type = this->_parse_stats_type(p);
	log_debug("parameter=%s -> stats_type=%d", p, this->_stats_type);
	delete[] p;

	if (this->_stats_type == stats_type_error) {
		return -1;
	}

	return 0;
}

int op_stats::_parse_binary_request(const binary_request_header& header, const char* body) {
	this->_stats_type = this->_parse_stats_type(std::string(body, header.get_total_body_length()).c_str());
	return this->_stats_type != stats_type_error ? 0 : -1;
}

int op_stats::_run_server() {
	return 0;
}

int op_stats::_send_stats(thread_pool* req_tp, thread_pool* other_tp, storage* st, cluster* cl) {
	rusage usage = stats_object->get_rusage();
	char usage_user[BUFSIZ];
	char usage_system[BUFSIZ];
	snprintf(usage_user, sizeof(usage_user), "%ld.%06d", usage.ru_utime.tv_sec, static_cast<int>(usage.ru_utime.tv_usec));
	snprintf(usage_system, sizeof(usage_user), "%ld.%06d", usage.ru_stime.tv_sec, static_cast<int>(usage.ru_stime.tv_usec));

	_send_stat("pid"									, stats_object->get_pid());
	_send_stat("uptime" 							, stats_object->get_uptime());
	_send_stat("time" 								, stats_object->get_timestamp());
	_send_stat("version"							, stats_object->get_version());
	_send_stat("pointer_size" 				, stats_object->get_pointer_size());
	_send_stat("rusage_user"					, usage_user);
	_send_stat("rusage_system"				, usage_system);
	_send_stat("curr_items" 					, stats_object->get_curr_items(st));
	_send_stat("total_items"					, stats_object->get_total_items());
	_send_stat("bytes"								, stats_object->get_bytes(st));
	_send_stat("curr_connections" 		, stats_object->get_curr_connections(req_tp, other_tp));
	_send_stat("total_connections"		, stats_object->get_total_connections());
	_send_stat("connection_structures", stats_object->get_connection_structures());
	_send_stat("cmd_get"							, stats_object->get_cmd_get());
	_send_stat("cmd_set"							, stats_object->get_cmd_set());
	_send_stat("get_hits" 						, stats_object->get_get_hits());
	_send_stat("get_misses" 					, stats_object->get_get_misses());
	_send_stat("delete_hits"					, stats_object->get_delete_hits());
	_send_stat("delete_misses"				, stats_object->get_delete_misses());
	_send_stat("incr_hits"						, stats_object->get_incr_hits());
	_send_stat("incr_misses"					, stats_object->get_incr_misses());
	_send_stat("decr_hits"						, stats_object->get_decr_hits());
	_send_stat("decr_misses"					, stats_object->get_decr_misses());
	_send_stat("cas_hits" 						, stats_object->get_cas_hits());
	_send_stat("cas_misses" 					, stats_object->get_cas_misses());
	_send_stat("cas_badval" 					, stats_object->get_cas_badval());
	_send_stat("touch_hits" 					, stats_object->get_touch_hits());
	_send_stat("touch_misses" 				, stats_object->get_touch_misses());
	_send_stat("evictions"						, stats_object->get_evictions());
	_send_stat("bytes_read" 					, stats_object->get_bytes_read());
	_send_stat("bytes_written"				, stats_object->get_bytes_written());
	_send_stat("limit_maxbytes" 			, stats_object->get_limit_maxbytes());
	_send_stat("threads"							, stats_object->get_threads(req_tp, other_tp));
	_send_stat("pool_threads" 				, stats_object->get_pool_threads(req_tp, other_tp));
	_send_stat("node_map_version"		, cl->get_node_map_version());

	return 0;
}

int op_stats::_send_stats_items() {
	return 0;
}

int op_stats::_send_stats_slabs() {
	return 0;
}

int op_stats::_send_stats_sizes() {
	return 0;
}

int op_stats::_send_stats(const thread::thread_info& info) {
	char key[BUFSIZ];
	char value[BUFSIZ];
	snprintf(key, sizeof(key), "%u:type", info.id);
	_send_stat(key, info.type);
	snprintf(key, sizeof(key), "%u:peer", info.id);
	snprintf(value, sizeof(value), "%s:%d", info.peer_name.c_str(), info.peer_port);
	_send_stat(key, value);
	snprintf(key, sizeof(key), "%u:op", info.id);
	_send_stat(key, info.op);
	snprintf(key, sizeof(key), "%u:uptime", info.id);
	_send_stat(key, stats_object->get_timestamp() - info.timestamp);
	snprintf(key, sizeof(key), "%u:state", info.id);
	_send_stat(key, info.state);
	snprintf(key, sizeof(key), "%u:info", info.id);
	_send_stat(key, info.info);
	snprintf(key, sizeof(key), "%u:queue", info.id);
	_send_stat(key, info.queue_size);
	snprintf(key, sizeof(key), "%u:behind", info.id);
	_send_stat(key, info.queue_behind);
	return 0;
}

int op_stats::_send_stats_threads(thread_pool* req_tp, thread_pool* other_tp) {
	{
		vector<thread::thread_info> list = req_tp->get_thread_info();
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	{
		vector<thread::thread_info> list = other_tp->get_thread_info();
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	return 0;
}

int op_stats::_send_stats_threads(thread_pool* req_tp, thread_pool* other_tp, int type) {
	{
		vector<thread::thread_info> list = req_tp->get_thread_info(type);
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	{
		vector<thread::thread_info> list = other_tp->get_thread_info(type);
		for (vector<thread::thread_info>::iterator it = list.begin(); it != list.end(); it++) {
			_send_stats(*it);
		}
	}
	return 0;
}

int op_stats::_send_stats_nodes(cluster* cl) {
	char key[BUFSIZ];
	vector<cluster::node> v = cl->get_node();
	for (vector<cluster::node>::iterator it = v.begin(); it != v.end(); it++) {
		string node_key = cl->to_node_key(it->node_server_name, it->node_server_port);
		snprintf(key, sizeof(key), "%s:role", node_key.c_str());
		_send_stat(key, cluster::role_cast(it->node_role));
		snprintf(key, sizeof(key), "%s:state", node_key.c_str());
		_send_stat(key, cluster::state_cast(it->node_state));
		snprintf(key, sizeof(key), "%s:partition", node_key.c_str());
		_send_stat(key, it->node_partition);
		snprintf(key, sizeof(key), "%s:balance", node_key.c_str());
		_send_stat(key, it->node_balance);
		snprintf(key, sizeof(key), "%s:thread_type", node_key.c_str());
		_send_stat(key, it->node_thread_type);
	}

	return 0;
}

int op_stats::_send_stats_threads_queue() {
	_send_stat("total_thread_queue", stats_object->get_total_thread_queue());

	return 0;
}

template<typename T>
int op_stats::_send_text_stat(const char* key, const T& value) {
	_text_stream << "STAT " << key << ' ' << value << line_delimiter;
	return 0;
}

template<typename T>
int op_stats::_send_binary_stat(const char* key, const T& value) {
	std::ostringstream body_os;
	body_os << key << value;
	const std::string& body = body_os.str();
	binary_response_header header(this->_opcode);
	header.set_key_length(strlen(key));
	header.set_total_body_length(body.size());
	return op::_send_binary_response(header, body.data(), true);
}

int op_stats::_send_text_result(result r, const char* message) {
	int result = 0;
	if (r == result_end) {
		_text_stream << "END" << line_delimiter;
		result = this->_connection->write(_text_stream.str().c_str(), _text_stream.str().size());
	}	else {
		result = op::_send_text_result(r, message);
	}
	_text_stream.str(std::string());
	return result;
}

int op_stats::_send_binary_result(result r, const char* message) {
	int result = 0;
	if (r == result_end) {
		result = op::_send_binary_response(binary_response_header(this->_opcode), NULL);
	} else {
		result = op::_send_binary_result(r, message);
	}
	_text_stream.str(std::string());
	return result;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
