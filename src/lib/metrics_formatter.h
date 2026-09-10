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
 *	metrics_formatter.h
 *
 *	memcached "stats" output -> Prometheus text exposition format.
 *
 *	Pure translation, no I/O: handler_metrics feeds it the parsed STAT
 *	key/value pairs and serves the result over HTTP. Metric names follow the
 *	community memcached_exporter (memcached_*) and flare_exporter (flared_*)
 *	conventions, with flare-specific storage/replication stats passed through
 *	as flare_node_rocksdb_*, so existing dashboards keep working unchanged.
 *	No instance labels are emitted: the scraper (e.g. a Prometheus PodMonitor)
 *	attaches pod/namespace itself, which is the point of per-node export —
 *	the metric's fault domain is exactly this process.
 */
#ifndef	METRICS_FORMATTER_H
#define	METRICS_FORMATTER_H

#include <string>
#include <utility>
#include <vector>

namespace gree {
namespace flare {

class metrics_formatter {
public:
	typedef std::vector<std::pair<std::string, std::string> > stats_list;

	// render the full /metrics payload from parsed `stats` (+ `stats threads
	// queue`) key/value pairs
	static std::string format(const stats_list& stats);

	// numeric literal check: digits with an optional single decimal point
	// (covers plain integers and flared's timeval "sec.usec" rusage format);
	// values are re-emitted verbatim so precision is never lost to a
	// float round-trip (curr_items at 8 digits would not survive %g)
	static bool is_numeric(const std::string& s);

private:
	static const std::string* _lookup(const stats_list& stats, const std::string& key);
	static void _append_sample(std::string& out, const std::string& name, const std::string& labels, const std::string& value);
};

}	// namespace flare
}	// namespace gree

#endif	// METRICS_FORMATTER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
