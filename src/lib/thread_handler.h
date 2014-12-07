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
 *	thread_handler.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	THREAD_HANDLER_H
#define	THREAD_HANDLER_H

#include "thread.h"

using namespace std;

namespace gree {
namespace flare {

/**
 *	thread handler base class
 */
class thread_handler {
protected:
	shared_thread			_thread;

public:
	thread_handler(shared_thread t): _thread(t) {};
	virtual ~thread_handler() {};

	virtual int run() = 0;

protected:
};

}	// namespace flare
}	// namespace gree

#endif	// THREAD_HANDLER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
