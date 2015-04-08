#include <handler_monitor.h>
#include <app.h>
#include "mock_cluster.h"
#include "connection_iostream.h"
#include <cppcutter.h>

namespace test_handler_monitor {

using namespace std;
using namespace gree::flare;

class handler_monitor_test : public handler_monitor {
public:
	handler_monitor_test(shared_thread t, cluster* cl, string node_server_name, int node_server_port):
		handler_monitor(t, cl, node_server_name, node_server_port) {
	}

	void set_connection(shared_connection con) {
		this->_connection = con;
	}

	using handler_monitor::_process_monitor;
	using handler_monitor::_tick_down;
	using handler_monitor::_tick_up;
	using handler_monitor::_is_node_map_version_mismatch_over_threshold;

protected:
	virtual void _setup() {
		this->_thread->set_peer(this->_node_server_name, this->_node_server_port);
		this->_thread->set_state("connect");

		shared_connection c(new connection_sstream(std::string()));
		this->_connection = c;
		this->_connection->set_connect_retry_limit(0);
	}

	virtual void _clear_read_buf() {
		// do nothing
	}
};



thread_pool* tp;
shared_thread t;
mock_cluster* cl;
shared_connection c;
handler_monitor_test* hm;

void setup() {
	stats_object = new stats();
	tp = new thread_pool(1);
	t = tp->get(thread_pool::thread_type_request);

	string server_name = "localhost";
	int server_port = 22222;
	int node_server_port = 22223;
	cl = new mock_cluster(server_name, server_port);

	shared_connection con(new connection_sstream(std::string()));
	c = con;

	hm = new handler_monitor_test(t, cl, server_name, node_server_port);
}

void teardown() {
	delete hm;
	c.reset();
	delete cl;
	tp->shutdown();
	t.reset();
	delete tp;
	delete stats_object;
}

void test_request_stats() {
	{
		shared_connection con(new connection_sstream(
			"STAT flare_node_status OK\r\n"
				"END\r\n"
		));
		hm->set_connection(con);
		cut_assert_equal_int(0, hm->_process_monitor());
		cut_assert_equal_string("stats\r\n", boost::static_pointer_cast<connection_sstream>(con)->get_output().c_str());
	}

	{
		shared_connection con(new connection_sstream(
			"STAT flare_node_status NG\r\n"
				"END\r\n"
		));
		hm->set_connection(con);
		cut_assert_equal_int(-1, hm->_process_monitor());
		cut_assert_equal_string("stats\r\n", boost::static_pointer_cast<connection_sstream>(con)->get_output().c_str());
	}
}

void test_fallback_and_request_ping() {
	{
		shared_connection con(new connection_sstream(
			"END\r\n" // response to "stats"
			"OK\r\n" // response to "ping"
		));
		hm->set_connection(con);
		cut_assert_equal_int(0, hm->_process_monitor());
		cut_assert_equal_string("stats\r\nping\r\n", boost::static_pointer_cast<connection_sstream>(con)->get_output().c_str());
	}

	{
		shared_connection con(new connection_sstream(
			"END\r\n" // response to "stats"
			"ERROR\r\n" // response to "ping"
		));
		hm->set_connection(con);
		cut_assert_equal_int(-1, hm->_process_monitor());
		cut_assert_equal_string("stats\r\nping\r\n", boost::static_pointer_cast<connection_sstream>(con)->get_output().c_str());
	}
}

void test_down() {
	hm->set_monitor_threshold(3);

	cut_assert_true(hm->_tick_down() == handler_monitor::keep_state);
	cut_assert_true(hm->_tick_down() == handler_monitor::keep_state);
	cut_assert_true(hm->_tick_down() == handler_monitor::should_modify_state);
	cut_assert_true(hm->_tick_down() == handler_monitor::keep_state);
}

void test_up() {
	hm->set_monitor_threshold(3);

	cut_assert_true(hm->_tick_up() == handler_monitor::keep_state);
	hm->_tick_down();
	hm->_tick_down();
	cut_assert_true(hm->_tick_down() == handler_monitor::should_modify_state);
	cut_assert_true(hm->_tick_up() == handler_monitor::should_modify_state);
	cut_assert_true(hm->_tick_up() == handler_monitor::keep_state);
}

void test_node_map_version() {
	hm->set_monitor_interval(11); // 11 sec
	cl->set_node_map_version(6);
	shared_connection con(new connection_sstream(
		"STAT flare_node_status NG\r\n"
			"STAT flare_node_map_version 5\r\n"
			"END\r\n"
			"STAT flare_node_status NG\r\n"
			"STAT flare_node_map_version 5\r\n"
			"END\r\n"
			"STAT flare_node_status NG\r\n"
			"STAT flare_node_map_version 5\r\n"
			"END\r\n"
			"STAT flare_node_status NG\r\n"
			"STAT flare_node_map_version 5\r\n"
			"END\r\n"
			"STAT flare_node_status NG\r\n"
			"STAT flare_node_map_version 6\r\n"
			"END\r\n"
	));
	hm->set_connection(con);

	hm->_process_monitor(); // 11 sec
	hm->_process_monitor(); // 22 sec
	cut_assert_false(hm->_is_node_map_version_mismatch_over_threshold());

	// threshold is 30 sec.
	hm->_process_monitor(); // 33 sec
	cut_assert_true(hm->_is_node_map_version_mismatch_over_threshold());
	hm->_process_monitor();
	cut_assert_true(hm->_is_node_map_version_mismatch_over_threshold());

	// after node_map updated
	hm->_process_monitor();
	cut_assert_false(hm->_is_node_map_version_mismatch_over_threshold());
}

}