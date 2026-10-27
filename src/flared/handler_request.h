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
 *	handler_request.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef HANDLER_REQUEST_H
#define HANDLER_REQUEST_H

#include "app.h"
#include "connection_tcp.h"

namespace gree {
namespace flare {

/**
 *	flare request handler class
 */
class handler_request : public thread_handler {
protected:
	shared_connection_tcp		_connection;

public:
	handler_request(shared_thread t, shared_connection_tcp c);
	virtual ~handler_request();

	virtual int run();

	// Set on a graceful stop (flared::shutdown): each request thread closes
	// its client connection after the request it is executing, instead of
	// reading the next one, so the stop does not interrupt a request.
	static void set_stop_after_request(bool v) { __atomic_store_n(&handler_request::_stop_after_request, v ? 1 : 0, __ATOMIC_SEQ_CST); };
	static bool is_stop_after_request() { return __atomic_load_n(&handler_request::_stop_after_request, __ATOMIC_SEQ_CST) != 0; };

private:
	static int _stop_after_request;
};

}	// namespace flare
}	// namespace gree

#endif // HANDLER_REQUEST_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
