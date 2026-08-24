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
 *	test_metrics_formatter.cc
 *
 *	memcached stats -> Prometheus text format translation
 */
#include <cppcutter.h>

#include <metrics_formatter.h>

using namespace std;
using namespace gree::flare;

namespace test_metrics_formatter
{
	metrics_formatter::stats_list stats;

	void setup() {
		stats.clear();
	}

	void teardown() {
	}

	void push(const char* key, const char* value) {
		stats.push_back(make_pair(string(key), string(value)));
	}

	bool contains(const string& haystack, const string& needle) {
		return haystack.find(needle) != string::npos;
	}

	void test_is_numeric() {
		cut_assert_true(metrics_formatter::is_numeric("0"));
		cut_assert_true(metrics_formatter::is_numeric("15829896"));
		cut_assert_true(metrics_formatter::is_numeric("10.962023"));		// rusage timeval
		cut_assert_true(metrics_formatter::is_numeric("-1"));
		cut_assert_false(metrics_formatter::is_numeric(""));
		cut_assert_false(metrics_formatter::is_numeric("-"));
		cut_assert_false(metrics_formatter::is_numeric("1.3.4"));			// version string
		cut_assert_false(metrics_formatter::is_numeric("1."));
		cut_assert_false(metrics_formatter::is_numeric(".5"));
		cut_assert_false(metrics_formatter::is_numeric("abc"));
		cut_assert_false(metrics_formatter::is_numeric("12a"));
	}

	// gauge/counter mapping keeps the exact original digits (no float
	// round-trip: 8-digit curr_items must survive verbatim)
	void test_gauges_verbatim() {
		push("curr_items", "15829896");
		push("bytes", "3128429267");
		push("uptime", "202");
		string out = metrics_formatter::format(stats);
		cut_assert_true(contains(out, "# TYPE memcached_current_items gauge\n"));
		cut_assert_true(contains(out, "memcached_current_items 15829896\n"));
		cut_assert_true(contains(out, "memcached_current_bytes 3128429267\n"));
		cut_assert_true(contains(out, "# TYPE memcached_uptime_seconds counter\n"));
		cut_assert_true(contains(out, "memcached_uptime_seconds 202\n"));
	}

	void test_commands_hit_miss() {
		push("get_hits", "10");
		push("get_misses", "4");
		push("cas_hits", "1");
		string out = metrics_formatter::format(stats);
		cut_assert_true(contains(out, "# TYPE memcached_commands_total counter\n"));
		cut_assert_true(contains(out, "memcached_commands_total{command=\"get\",status=\"hit\"} 10\n"));
		cut_assert_true(contains(out, "memcached_commands_total{command=\"get\",status=\"miss\"} 4\n"));
		cut_assert_true(contains(out, "memcached_commands_total{command=\"cas\",status=\"hit\"} 1\n"));
	}

	// set = cmd_set - (cas_hits + cas_misses + cas_badval), matching flare_exporter
	void test_derived_set_excludes_cas() {
		push("cmd_set", "100");
		push("cas_hits", "5");
		push("cas_misses", "3");
		push("cas_badval", "2");
		string out = metrics_formatter::format(stats);
		cut_assert_true(contains(out, "memcached_commands_total{command=\"set\",status=\"hit\"} 90\n"));
	}

	void test_version_label() {
		push("version", "1.3.4");
		string out = metrics_formatter::format(stats);
		cut_assert_true(contains(out, "flared_version{version=\"1.3.4\"} 1\n"));
	}

	void test_flared_gauges() {
		push("node_map_version", "12884902097");
		push("total_thread_queue", "0");
		push("rusage_user", "10.962023");
		string out = metrics_formatter::format(stats);
		cut_assert_true(contains(out, "flared_node_map_version 12884902097\n"));
		cut_assert_true(contains(out, "flared_thread_queue_total 0\n"));
		cut_assert_true(contains(out, "flared_process_user_cpu_seconds_total 10.962023\n"));
	}

	// data-dir usage (statvfs): the tmpfs-RAM truth that container-level
	// memory metrics miss — must reach /metrics for the dashboards.
	void test_data_dir_usage_gauges() {
		push("data_dir_used_bytes", "3340763136");
		push("data_dir_capacity_bytes", "8589934592");
		string out = metrics_formatter::format(stats);
		cut_assert_true(contains(out, "flare_node_data_dir_used_bytes 3340763136\n"));
		cut_assert_true(contains(out, "flare_node_data_dir_capacity_bytes 8589934592\n"));
	}

	// every rocksdb_* stat passes through without a per-key allowlist, so new
	// flared stats show up in /metrics automatically
	void test_rocksdb_passthrough() {
		push("rocksdb_wal_fallback_to_dump", "0");
		push("rocksdb_snapshot_bootstrap", "1");
		push("rocksdb_expire_reaped", "265");
		string out = metrics_formatter::format(stats);
		cut_assert_true(contains(out, "flare_node_rocksdb_wal_fallback_to_dump 0\n"));
		cut_assert_true(contains(out, "flare_node_rocksdb_snapshot_bootstrap 1\n"));
		cut_assert_true(contains(out, "flare_node_rocksdb_expire_reaped 265\n"));
	}

	// non-numeric values must never leak into a sample line (Prometheus
	// rejects the whole scrape on a malformed sample)
	void test_non_numeric_skipped() {
		push("curr_items", "garbage");
		push("rocksdb_wal_enabled", "true");
		string out = metrics_formatter::format(stats);
		cut_assert_false(contains(out, "garbage"));
		cut_assert_false(contains(out, "true"));
		cut_assert_false(contains(out, "memcached_current_items"));
	}

	void test_absent_stats_emit_nothing() {
		string out = metrics_formatter::format(stats);
		cut_assert_equal_string("", out.c_str());
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
