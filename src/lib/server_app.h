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
	volatile bool									_shutdown_request;
	volatile bool									_reload_request;
	pthread_mutex_t								_mutex_reload_request;
	pthread_t											_signal_thread_id;
	pthread_t											_main_thread_id;

public:
	server_app();
	~server_app();

protected:
	static void* _signal_thread_run(void*);
	static void _sa_usr1_handler(int sig);
	int _setup_signal_handler();
	void _reload_if_requested();
	void _sigusr1_flag_check();
};

}	// namespace flare
}	// namespace gree

#endif	// SERVER_APP_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
