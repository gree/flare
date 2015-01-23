/*
* Flare
* --------------
* Copyright (C) 2008-2015 GREE, Inc.
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public License
* as published by the Free Software Foundation; either version 2
* of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program; if not, write to the Free Software
* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
*/
/**
 *	server_app.h
 *
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */
#ifndef	SERVER_APP_H
#define	SERVER_APP_H
#include "app.h"

using namespace std;

namespace gree {
namespace flare {

class server_app : public app {
protected:
	static volatile sig_atomic_t	_sigusr1_flag;
	volatile bool _shutdown_requested;
	volatile bool _reload_requested;
	pthread_mutex_t								_mutex_reload_request;
	pthread_t											_signal_thread_id;
	pthread_t											_main_thread_id;

public:
	server_app();
	~server_app();

protected:
	static void* _signal_thread_run(void*);
	static void _sa_usr1_handler(int sig);
	int _startup_signal_handler();
	int _shutdown_signal_handler();
	void _reload_if_requested();
	void _sigusr1_flag_check();
};

}	// namespace flare
}	// namespace gree

#endif	// SERVER_APP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
