/**
 *	handler_request.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __HANDLER_REQUEST_H__
#define __HANDLER_REQUEST_H__

#include "app.h"
#include "op_parser_binary_manager.h"
#include "op_parser_text_manager.h"

namespace gree {
namespace flare {

/**
 *	flare request handler class
 */
class handler_request : public thread_handler {
protected:
	shared_connection			_connection;

public:
	handler_request(shared_thread t, shared_connection c);
	virtual ~handler_request();

	virtual int run();
};

}	// namespace flare
}	// namespace gree

#endif // __HANDLER_REQUEST_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
