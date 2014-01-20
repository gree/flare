/**
 *	handler_alarm.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef HANDLER_ALARM_H
#define HANDLER_ALARM_H

#include "app.h"

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

#endif // HANDLER_ALARM_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
