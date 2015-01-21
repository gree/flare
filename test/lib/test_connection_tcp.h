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
 *	test_connection_tcp.h
 *
 *	Asynchronous server for tests
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <string>

#include <pthread.h>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cppcutter.h>
#include <netinet/in.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>

namespace test_connection_tcp
{
	class server
	{
		public:
			server(const std::string& output);
			~server();

			void start();
			void stop();

			static void* run(void*);

			unsigned short get_port() const { return _port; }

		private:
			struct thread_args
			{
				thread_args(CutTestContext* context, server* instance): _context(context), _instance(instance) { }
				CutTestContext* const _context;
				server* const _instance;
			};

			const std::string _output;
			unsigned short _port;
			int _sfd;
			pthread_t _thread;
			bool _running;
	};

	server::server(const std::string& output)
		: _output(output),
		_port(0),
		_sfd(0),
		_running(false)
	{
		srand(time(NULL));
		_sfd = socket(AF_INET, SOCK_STREAM, 0);
		int opt_true = 1;
		setsockopt(_sfd, SOL_SOCKET, SO_REUSEADDR, (char*)&opt_true, sizeof(opt_true));
#ifdef SO_REUSEPORT
		setsockopt(_sfd, SOL_SOCKET, SO_REUSEPORT, (char*)&opt_true, sizeof(opt_true));
#endif
		sockaddr_in addr;
		memset(&addr, 0, sizeof(addr));
		addr.sin_family = AF_INET;
		addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		bool bound = false;
		do {
			_port = rand() % (65535 - 1024) + 1024;
			addr.sin_port = htons(_port);
			bound = !bind(_sfd, (const sockaddr*)&addr, sizeof(addr));
		} while (!bound);
		start();
	}

	server::~server()
	{
		stop();
	}

	void server::start()
	{
		_running = true;
		pthread_create(&_thread, NULL, &server::run, (void*)new thread_args(cut_get_current_test_context(), this));
	}

	void server::stop()
	{
		shutdown(_sfd, 2);
		_running = false;
		pthread_join(_thread, NULL);
	}

	void* server::run(void* arg)
	{
		thread_args* args = (thread_args*)arg;
		server& instance = *(args->_instance);
		cut_set_current_test_context(args->_context);
		delete args;
		listen(instance._sfd, 1);
		sockaddr_in addr;
		socklen_t addrlen = sizeof(addr);
		int nsfd = accept(instance._sfd, (sockaddr*)&addr, &addrlen);
		if (instance._output.size() > 0) {
			send(nsfd, instance._output.data(), instance._output.size(), MSG_DONTWAIT);
		}
		while(instance._running) { sleep(1); }
		pthread_exit(NULL);
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
