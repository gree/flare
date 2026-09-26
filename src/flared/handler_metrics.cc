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
 *	handler_metrics.cc
 *
 *	implementation of gree::flare::handler_metrics
 */
#include "handler_metrics.h"
#include "server.h"
#include "util.h"

#include <stdio.h>
#include <string.h>

namespace gree {
namespace flare {

namespace {
// scrapes are infrequent (Prometheus default 15-60s); keep every socket
// interaction on a short leash so a stuck peer can never pin this thread
const int timeout_msec = 5 * 1000;
// upper bound on STAT lines read from the self-scrape (a sane stats block is
// a few hundred lines; this is a runaway guard, not a limit to tune)
const int max_stat_lines = 10000;
}	// anonymous namespace

// {{{ ctor/dtor
handler_metrics::handler_metrics(shared_thread t, int metrics_port, int node_port):
		thread_handler(t),
		_metrics_port(metrics_port),
		_node_port(node_port) {
}

handler_metrics::~handler_metrics() {
}
// }}}

// {{{ public methods
/**
 *	run thread proc
 */
int handler_metrics::run() {
	this->_thread->set_state("wait");
	this->_thread->set_op("");

	server* s = new server();
	if (s->listen(this->_metrics_port) < 0) {
		log_err("failed to listen on metrics port (port=%d)", this->_metrics_port);
		delete s;
		return -1;
	}
	log_notice("metrics endpoint ready (port=%d, self-scrape port=%d)", this->_metrics_port, this->_node_port);

	for (;;) {
		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			this->_thread->set_state("shutdown");
			break;
		}

		vector<shared_connection_tcp> connection_list = s->wait();

		if (this->_thread->is_shutdown_request()) {
			log_info("thread shutdown request -> breaking loop", 0);
			this->_thread->set_state("shutdown");
			break;
		}

		for (vector<shared_connection_tcp>::iterator it = connection_list.begin(); it != connection_list.end(); it++) {
			this->_thread->set_state("execute");
			this->_thread->set_op("metrics");
			this->_serve(*it);
			this->_thread->set_state("wait");
			this->_thread->set_op("");
		}
	}

	delete s;
	return 0;
}
// }}}

// {{{ protected methods
/**
 *	gather stats over a loopback connection to this node's own request port
 */
int handler_metrics::_self_scrape(metrics_formatter::stats_list& stats) {
	shared_connection_tcp c(new connection_tcp("127.0.0.1", this->_node_port));
	if (c->open() < 0) {
		return -1;
	}
	c->set_read_timeout(timeout_msec);

	// pipeline both blocks; each is terminated by its own END line
	// (`stats threads queue` carries total_thread_queue)
	const char* request = "stats\r\nstats threads queue\r\n";
	if (c->write(request, strlen(request)) < 0) {
		return -1;
	}

	int end_count = 0;
	for (int i = 0; i < max_stat_lines && end_count < 2; i++) {
		char* p;
		if (c->readline(&p) < 0) {
			return -1;
		}
		char q[BUFSIZ];
		int n = util::next_word(p, q, sizeof(q));
		if (strcmp(q, "END") == 0) {
			end_count++;
		} else if (strcmp(q, "STAT") == 0) {
			char key[BUFSIZ];
			n += util::next_word(p + n, key, sizeof(key));
			char value[BUFSIZ];
			util::next_word(p + n, value, sizeof(value));
			if (key[0] != '\0') {
				stats.push_back(make_pair(string(key), string(value)));
			}
		}
		delete[] p;
	}

	return end_count == 2 ? 0 : -1;
}

/**
 *	answer one HTTP request (any GET path -> the metrics payload)
 */
void handler_metrics::_serve(shared_connection_tcp c) {
	c->set_read_timeout(timeout_msec);

	// consume the request head (request line + headers up to the blank line);
	// the path is not inspected — like most exporters, every path serves the
	// metrics so probes and scrapers cannot disagree about the URL
	for (int i = 0; i < 100; i++) {
		char* p;
		if (c->readline(&p) < 0) {
			return;
		}
		bool blank = (p[0] == '\0' || p[0] == '\n' || (p[0] == '\r' && p[1] == '\n'));
		delete[] p;
		if (blank) {
			break;
		}
	}

	metrics_formatter::stats_list stats;
	string status;
	string body;
	if (this->_self_scrape(stats) == 0) {
		status = "200 OK";
		body = metrics_formatter::format(stats);
	} else {
		// a failed self-scrape means THIS node cannot answer stats (wedged
		// worker threads, storage stall): surface it as a scrape error
		status = "503 Service Unavailable";
		body = "self-scrape failed\n";
		log_warning("metrics self-scrape failed (port=%d)", this->_node_port);
	}

	char header[256];
	snprintf(header, sizeof(header),
			"HTTP/1.0 %s\r\n"
			"Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
			"Content-Length: %lu\r\n"
			"Connection: close\r\n"
			"\r\n",
			status.c_str(), static_cast<unsigned long>(body.size()));
	string response = string(header) + body;
	c->write(response.c_str(), response.size());
}
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
