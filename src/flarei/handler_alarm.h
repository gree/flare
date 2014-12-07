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
 *	handler_alarm.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef HANDLER_ALARM_H
#define HANDLER_ALARM_H

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

#endif // HANDLER_ALARM_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
