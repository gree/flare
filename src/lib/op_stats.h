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
 *	op_stats.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	OP_STATS_H
#define	OP_STATS_H

#include <sstream>
#include <string>

#include "op.h"
#include "cluster.h"
#include "storage.h"
#include "thread_pool.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	opcode class (stats)
 */
class op_stats : public op {
protected:
	enum			stats_type {
		stats_type_error = -1,
		stats_type_default,
		stats_type_items,
		stats_type_slabs,
		stats_type_sizes,
		stats_type_threads,
		stats_type_threads_request,
		stats_type_threads_slave,
		stats_type_nodes,
		stats_type_threads_queue,
	};

	stats_type	_stats_type;

public:
	op_stats(shared_connection c);
	virtual ~op_stats();

protected:
	virtual int _parse_text_server_parameters();
	virtual int _parse_binary_request(const binary_request_header&, const char* body);
	virtual int _run_server();

	virtual int _send_stats(thread_pool* req_tp, thread_pool* other_tp, storage* st, cluster* cl);
	virtual int _send_stats_items();
	virtual int _send_stats_slabs();
	virtual int _send_stats_sizes();
	virtual int _send_stats_threads(thread_pool* req_tp, thread_pool* other_tp);
	virtual int _send_stats_threads(thread_pool* req_tp, thread_pool* other_tp, int type);
	virtual int _send_stats_nodes(cluster* cl);
	virtual int _send_stats_threads_queue();

	virtual int _send_text_result(result r, const char* message = NULL);
	virtual int _send_binary_result(result r, const char* message = NULL);

private:
	stats_type _parse_stats_type(const char* body) const;

	template<typename T> inline int _send_stat(const char* key, const T& value);
	template<typename T> int _send_text_stat(const char* key, const T& value);
	template<typename T> int _send_binary_stat(const char* key, const T& value);
	int _send_stats(const thread::thread_info&);

	std::ostringstream _text_stream;
};

template<typename T> int op_stats::_send_stat(const char* key, const T& value) {
	return _protocol == op::text
		? _send_text_stat<T>(key, value)
		: _send_binary_stat<T>(key, value);
}

}	// namespace flare
}	// namespace gree

#endif	// OP_STATS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
