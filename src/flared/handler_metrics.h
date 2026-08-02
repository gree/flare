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
 *	handler_metrics.h
 *
 *	native Prometheus /metrics endpoint
 */
#ifndef	HANDLER_METRICS_H
#define	HANDLER_METRICS_H

#include "app.h"
#include "connection_tcp.h"
#include "metrics_formatter.h"

namespace gree {
namespace flare {

/**
 *	thread serving GET /metrics in Prometheus text format on a dedicated port.
 *
 *	Each node exports its own metrics so the metric's fault domain is exactly
 *	this process — no central collector sits between the node and Prometheus
 *	(a collector outage used to blank out every node's series at once, which is
 *	indistinguishable from a real outage during triage).
 *
 *	The stats are gathered by a loopback memcached connection to this node's
 *	own request port rather than by reading internals directly: it reuses the
 *	op_stats code path verbatim (one source of truth for stat computation), and
 *	a flared whose worker threads are wedged fails the self-scrape — turning
 *	the wedge into a scrape error, which is the correct signal to raise.
 */
class handler_metrics : public thread_handler {
protected:
	int		_metrics_port;
	int		_node_port;

public:
	handler_metrics(shared_thread t, int metrics_port, int node_port);
	virtual ~handler_metrics();

	virtual int run();

protected:
	int _self_scrape(metrics_formatter::stats_list& stats);
	void _serve(shared_connection_tcp c);
};

}	// namespace flare
}	// namespace gree

#endif	// HANDLER_METRICS_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
