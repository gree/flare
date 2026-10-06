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
 *	test_connection_tcp.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */
#include <cppcutter.h>

#include "test_connection_tcp.h"

#include "common_connection_tests.h"
#include <app.h>
#include <connection_tcp.h>

#include <iostream>
#include <time.h>
#include <errno.h>
#include <arpa/inet.h>

using namespace gree::flare;

namespace test_connection_tcp
{
	server* server_object;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
		server_object = NULL;
	}

	connection* new_connection_tcp(const std::string& input, int* timeout = NULL)
	{
		server_object = new server(input);
		connection_tcp* instance = new connection_tcp("localhost", server_object->get_port());
		if (timeout)
			instance->set_read_timeout(*timeout);
		cut_assert_equal_string("localhost", instance->get_host().c_str());
		cut_assert_equal_int(server_object->get_port(), instance->get_port());
		sleep(1);
		return instance;
	}

	connection* connection_tcp_factory(const std::string& input)
	{
		int one_second = 1000;
		return new_connection_tcp(input, &one_second);
	}

	COMMON_CONNECTION_TEST(connection_tcp, readsize_basic);
	COMMON_CONNECTION_TEST(connection_tcp, readsize_zero);
	COMMON_CONNECTION_TEST(connection_tcp, readsize_empty);
	COMMON_CONNECTION_TEST(connection_tcp, readline_basic);
	COMMON_CONNECTION_TEST(connection_tcp, readline_unix);
	COMMON_CONNECTION_TEST(connection_tcp, push_back_basic);

	struct connection_tcp_test : public connection_tcp
	{
		using connection_tcp::_addr_family;
		using connection_tcp::_sock;
		using connection_tcp::_read_buf;
		using connection_tcp::_read_buf_p;
		using connection_tcp::_read_buf_len;
	};

	void test_connection_tcp_readsize_greedy()
	{
		shared_connection c(new_connection_tcp("short"));
		c->open();
		connection_tcp& ctcp = dynamic_cast<connection_tcp&>(*c);
		cut_assert_equal_int(10*60*1000, ctcp.get_read_timeout());
		cut_assert_equal_int(0, ctcp.set_read_timeout(1000)); // 1s.
		cut_assert_equal_int(1000, ctcp.get_read_timeout());
		char* buffer = NULL;
		cut_assert_equal_int(-1, c->readsize(10, &buffer));
		cut_assert_equal_int(0, static_cast<connection_tcp_test&>(*c)._read_buf_len);
		delete[] buffer;
	}
	
	void test_connection_tcp_readline_no_newline()
	{
		shared_connection c(new_connection_tcp("1 line only!"));
		c->open();
		connection_tcp& ctcp = dynamic_cast<connection_tcp&>(*c);
		cut_assert_equal_int(10*60*1000, ctcp.get_read_timeout());
		cut_assert_equal_int(0, ctcp.set_read_timeout(1000)); // 1s.
		cut_assert_equal_int(1000, ctcp.get_read_timeout());
		char* buffer = NULL;
		cut_assert_equal_int(-1, c->readline(&buffer));
		cut_assert_equal_int(0, static_cast<connection_tcp_test&>(*c)._read_buf_len);
		delete[] buffer;
	}

	void test_connection_tcp_check_internal_buffer()
	{
		shared_connection c(new_connection_tcp("0123456789"));
		c->open();
		char* buffer = NULL;
		bool actual;
		cut_assert_equal_int(5, c->read(&buffer, 5, false, actual));
		cut_assert_equal_substring("01234", buffer, 5);
		cut_assert_equal_boolean(true, actual);
		delete[] buffer;
		buffer = NULL;
		cut_assert_equal_substring("0123456789", static_cast<connection_tcp_test&>(*c)._read_buf, 10);
		cut_assert_equal_int(5, static_cast<connection_tcp_test&>(*c)._read_buf_len);
		cut_assert_equal_substring("56789", static_cast<connection_tcp_test&>(*c)._read_buf_p, 5);
		cut_assert_equal_int(5, c->read(&buffer, 5, false, actual));
		cut_assert_equal_substring("56789", buffer, 5);
		cut_assert_equal_boolean(false, actual);
		delete[] buffer;
	}

	bool get_tcp_nodelay(sa_family_t addr_family, int sock)
	{
		cut_assert(addr_family != AF_UNIX);
		int flag = 0;
		socklen_t flaglen = sizeof(flag);
		cut_assert_equal_int(0,
			      getsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<char*>(&flag), &flaglen));
		return flag?true:false;
	}

	void test_connection_tcp_nodelay()
	{
		shared_connection c(new_connection_tcp(""));
		c->open();
		connection_tcp_test& ctcp = static_cast<connection_tcp_test&>(*c);
		bool nodelay;
		cut_assert_equal_int(0, ctcp.get_tcp_nodelay(nodelay));
		cut_assert_equal_boolean(false, nodelay);
		cut_assert_equal_boolean(false, get_tcp_nodelay(ctcp._addr_family, ctcp._sock));

		cut_assert_equal_int(0, ctcp.set_tcp_nodelay(true));
		cut_assert_equal_int(0, ctcp.get_tcp_nodelay(nodelay));
		cut_assert_equal_boolean(true, nodelay);
		cut_assert_equal_boolean(true, get_tcp_nodelay(ctcp._addr_family, ctcp._sock));

		cut_assert_equal_int(0, ctcp.set_tcp_nodelay(false));
		cut_assert_equal_int(0, ctcp.get_tcp_nodelay(nodelay));
		cut_assert_equal_boolean(false, nodelay);
		cut_assert_equal_boolean(false, get_tcp_nodelay(ctcp._addr_family, ctcp._sock));
	}

	// ---- deadlines (review 2026-10-06): a per-read timeout bounds a SILENT
	// peer; only the total deadline bounds a peer that TRICKLES bytes; the
	// connect deadline bounds an address that never answers.
	namespace {
		uint64_t mono_ms() {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
		}
		struct trickle_server {
			int sfd;
			unsigned short port;
			pthread_t th;
			trickle_server() : sfd(-1), port(0) {
				sfd = socket(AF_INET, SOCK_STREAM, 0);
				int on = 1;
				setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
				struct sockaddr_in a;
				memset(&a, 0, sizeof(a));
				a.sin_family = AF_INET;
				a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
				a.sin_port = 0;
				bind(sfd, (struct sockaddr*)&a, sizeof(a));
				socklen_t len = sizeof(a);
				getsockname(sfd, (struct sockaddr*)&a, &len);
				port = ntohs(a.sin_port);
				listen(sfd, 4);
				pthread_create(&th, NULL, &trickle_server::run, this);
			}
			static void* run(void* p) {
				trickle_server* self = static_cast<trickle_server*>(p);
				int c = accept(self->sfd, NULL, NULL);
				if (c < 0) return NULL;
				for (int i = 0; i < 20; i++) {		// 6 s of one byte / 300 ms, never a newline
					if (write(c, "a", 1) != 1) break;
					usleep(300 * 1000);
				}
				close(c);
				return NULL;
			}
			~trickle_server() {
				pthread_join(th, NULL);
				close(sfd);
			}
		};
	}

	void test_connection_tcp_read_timeout_bounds_a_silent_peer()
	{
		// the test server sends its output and then HOLDS the connection
		shared_connection c(new_connection_tcp("no newline, then silence"));
		cut_assert_equal_int(0, c->open());
		connection_tcp& ctcp = dynamic_cast<connection_tcp&>(*c);
		ctcp.set_read_timeout(1000);
		char* line = NULL;
		const uint64_t t0 = mono_ms();
		cut_assert_equal_int(-1, c->readline(&line));
		const uint64_t took = mono_ms() - t0;
		// the per-read TIMEOUT ended it (not the peer closing: that is -2)
		cut_assert_equal_int(-1, ctcp.get_errno());
		cut_assert_operator(took, >=, (uint64_t)900);
		cut_assert_operator(took, <, (uint64_t)3000);
		delete[] line;
	}

	void test_connection_tcp_total_deadline_bounds_a_trickling_peer()
	{
		trickle_server srv;
		connection_tcp* t = new connection_tcp("localhost", srv.port);
		shared_connection c(t);
		t->set_read_timeout(1000);			// never fires: a byte arrives every 300 ms
		cut_assert_equal_int(0, c->open());
		t->set_deadline_from_now(1500);
		char* line = NULL;
		const uint64_t t0 = mono_ms();
		cut_assert_equal_int(-1, c->readline(&line));
		const uint64_t took = mono_ms() - t0;
		cut_assert_equal_int(-3, t->get_errno());			// the TOTAL deadline ended it
		cut_assert_operator(took, <, (uint64_t)3000);		// not the 6 s of trickling
		cut_assert_operator(took, >=, (uint64_t)1400);
		delete[] line;
	}

	void test_connection_tcp_connect_deadline_bounds_an_unanswered_address()
	{
		// 192.0.2.1 (TEST-NET-1, RFC 5737) is never routed: either the
		// connect is refused at once or it would wait for the kernel's SYN
		// timeout; with a deadline it must give up within the deadline.
		connection_tcp* t = new connection_tcp("192.0.2.1", 9);
		shared_connection c(t);
		t->set_connect_timeout_ms(1000);
		t->set_connect_retry_limit(1);
		const uint64_t t0 = mono_ms();
		cut_assert_equal_int(-1, c->open());
		const uint64_t took = mono_ms() - t0;
		if (t->get_errno() != ETIMEDOUT) {
			// refused or unreachable at once: the DEADLINE path was not reached
			// (this network answers for TEST-NET-1). Not a pass of this test.
			cut_omit("connect to 192.0.2.1 failed immediately (errno %d): the connect deadline was not exercised here", t->get_errno());
		}
		cut_assert_operator(took, >=, (uint64_t)1800);		// two 1 s deadlines
		cut_assert_operator(took, <, (uint64_t)5000);		// 2 tries x 1 s + retry wait
	}

	void teardown()
	{
		delete stats_object;
		delete server_object;
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
