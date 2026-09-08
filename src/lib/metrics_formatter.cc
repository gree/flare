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
 *	metrics_formatter.cc
 *
 *	implementation of gree::flare::metrics_formatter
 */
#include "metrics_formatter.h"

#include <stdio.h>
#include <stdlib.h>

using namespace std;

namespace gree {
namespace flare {

namespace {

struct stat_mapping {
	const char* stat_key;
	const char* metric_name;
	const char* prom_type;
};

// memcached-origin stats under the standard prometheus/memcached_exporter
// names, so community memcached Grafana dashboards are drop-in
const stat_mapping memcached_gauges[] = {
	{ "curr_items",        "memcached_current_items",       "gauge"   },
	{ "bytes",             "memcached_current_bytes",       "gauge"   },
	{ "limit_maxbytes",    "memcached_limit_bytes",         "gauge"   },
	{ "curr_connections",  "memcached_current_connections", "gauge"   },
	{ "total_connections", "memcached_connections_total",   "counter" },
	{ "total_items",       "memcached_items_total",         "counter" },
	{ "bytes_read",        "memcached_read_bytes_total",    "counter" },
	{ "bytes_written",     "memcached_written_bytes_total", "counter" },
	{ "evictions",         "memcached_items_evicted_total", "counter" },
	{ "uptime",            "memcached_uptime_seconds",      "counter" },
	{ "time",              "memcached_time_seconds",        "gauge"   },
};

struct command_mapping {
	const char* stat_key;
	const char* command;
	const char* status;
};

// hit/miss-style stats -> memcached_commands_total{command,status}
const command_mapping memcached_commands[] = {
	{ "get_hits",      "get",    "hit"    },
	{ "get_misses",    "get",    "miss"   },
	{ "delete_hits",   "delete", "hit"    },
	{ "delete_misses", "delete", "miss"   },
	{ "incr_hits",     "incr",   "hit"    },
	{ "incr_misses",   "incr",   "miss"   },
	{ "decr_hits",     "decr",   "hit"    },
	{ "decr_misses",   "decr",   "miss"   },
	{ "touch_hits",    "touch",  "hit"    },
	{ "touch_misses",  "touch",  "miss"   },
	{ "cas_hits",      "cas",    "hit"    },
	{ "cas_misses",    "cas",    "miss"   },
	{ "cas_badval",    "cas",    "badval" },
};

// flared-specific numeric stats under flared_* (wire-compatible with
// flare_exporter); rusage_user/system are timeval strings "sec.usec" which
// pass the numeric check and are emitted verbatim as fixed-point seconds
const stat_mapping flared_gauges[] = {
	{ "node_map_version",   "flared_node_map_version",                 "gauge"   },
	{ "proxy_write_dropped",     "flare_node_proxy_write_dropped",     "counter" },
	{ "data_dir_used_bytes",     "flare_node_data_dir_used_bytes",     "gauge"   },
	{ "data_dir_capacity_bytes", "flare_node_data_dir_capacity_bytes", "gauge"   },
	{ "total_thread_queue", "flared_thread_queue_total",               "gauge"   },
	{ "rusage_user",        "flared_process_user_cpu_seconds_total",   "counter" },
	{ "rusage_system",      "flared_process_system_cpu_seconds_total", "counter" },
};

void append_header(string& out, const string& name, const char* prom_type) {
	out += "# HELP " + name + " flared stat\n";
	out += "# TYPE " + name + " " + prom_type + "\n";
}

}	// anonymous namespace

// {{{ public methods
bool metrics_formatter::is_numeric(const string& s) {
	if (s.empty()) {
		return false;
	}
	string::size_type i = 0;
	if (s[0] == '-') {
		i = 1;
		if (s.size() == 1) {
			return false;
		}
	}
	bool seen_dot = false;
	bool seen_digit = false;
	for (; i < s.size(); i++) {
		char c = s[i];
		if (c == '.') {
			if (seen_dot || !seen_digit || i + 1 >= s.size()) {
				return false;
			}
			seen_dot = true;
		} else if (c >= '0' && c <= '9') {
			seen_digit = true;
		} else {
			return false;
		}
	}
	return seen_digit;
}

string metrics_formatter::format(const stats_list& stats) {
	string out;
	out.reserve(4096);

	for (size_t i = 0; i < sizeof(memcached_gauges) / sizeof(memcached_gauges[0]); i++) {
		const stat_mapping& m = memcached_gauges[i];
		const string* v = _lookup(stats, m.stat_key);
		if (v && is_numeric(*v)) {
			append_header(out, m.metric_name, m.prom_type);
			_append_sample(out, m.metric_name, "", *v);
		}
	}

	bool command_header = false;
	for (size_t i = 0; i < sizeof(memcached_commands) / sizeof(memcached_commands[0]); i++) {
		const command_mapping& m = memcached_commands[i];
		const string* v = _lookup(stats, m.stat_key);
		if (v && is_numeric(*v)) {
			if (!command_header) {
				append_header(out, "memcached_commands_total", "counter");
				command_header = true;
			}
			_append_sample(out, "memcached_commands_total",
					string("command=\"") + m.command + "\",status=\"" + m.status + "\"", *v);
		}
	}
	// set = cmd_set - (cas_hits + cas_misses + cas_badval), matching
	// flare_exporter (cmd_set counts CAS operations too; the cas breakdown is
	// emitted above)
	const string* cmd_set = _lookup(stats, "cmd_set");
	if (cmd_set && is_numeric(*cmd_set)) {
		long long set_count = atoll(cmd_set->c_str());
		const char* cas_keys[] = { "cas_hits", "cas_misses", "cas_badval" };
		for (size_t i = 0; i < 3; i++) {
			const string* cas = _lookup(stats, cas_keys[i]);
			if (cas && is_numeric(*cas)) {
				set_count -= atoll(cas->c_str());
			}
		}
		if (!command_header) {
			append_header(out, "memcached_commands_total", "counter");
			command_header = true;
		}
		char buf[32];
		snprintf(buf, sizeof(buf), "%lld", set_count);
		_append_sample(out, "memcached_commands_total", "command=\"set\",status=\"hit\"", buf);
	}

	// flared_version{version}: constant 1, version carried as a label
	const string* version = _lookup(stats, "version");
	if (version) {
		append_header(out, "flared_version", "gauge");
		_append_sample(out, "flared_version", "version=\"" + *version + "\"", "1");
	}

	for (size_t i = 0; i < sizeof(flared_gauges) / sizeof(flared_gauges[0]); i++) {
		const stat_mapping& m = flared_gauges[i];
		const string* v = _lookup(stats, m.stat_key);
		if (v && is_numeric(*v)) {
			append_header(out, m.metric_name, m.prom_type);
			_append_sample(out, m.metric_name, "", *v);
		}
	}

	// storage/replication/backup extras: pass through EVERY rocksdb_* stat as
	// flare_node_rocksdb_* so new flared stats (reaper, snapshot bootstrap, ...)
	// are exported without touching this table again
	for (stats_list::const_iterator it = stats.begin(); it != stats.end(); it++) {
		if (it->first.compare(0, 8, "rocksdb_") == 0 && is_numeric(it->second)) {
			string name = "flare_node_" + it->first;
			append_header(out, name, "gauge");
			_append_sample(out, name, "", it->second);
		}
	}

	return out;
}
// }}}

// {{{ protected methods
const string* metrics_formatter::_lookup(const stats_list& stats, const string& key) {
	for (stats_list::const_iterator it = stats.begin(); it != stats.end(); it++) {
		if (it->first == key) {
			return &it->second;
		}
	}
	return NULL;
}

void metrics_formatter::_append_sample(string& out, const string& name, const string& labels, const string& value) {
	out += name;
	if (!labels.empty()) {
		out += "{" + labels + "}";
	}
	out += " " + value + "\n";
}
// }}}

}	// namespace flare
}	// namespace gree
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
