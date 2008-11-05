/**
 *	handler_alarm.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __HANDLER_ALARM_H__
#define __HANDLER_ALARM_H__

#include "app.h"
#include "op_parser_binary_index.h"
#include "op_parser_text_index.h"

namespace gree {
namespace flare {

/**
 *	flare alarm handler class
 */
class handler_alarm : public thread_handler {
protected:

public:
	handler_alarm(shared_thread t);
	virtual ~handler_alarm();

	virtual int run();
};

}	// namespace flare
}	// namespace gree

#endif // __HANDLER_ALARM_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
