/**
 *	test_cluster.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include <fstream>

#include <app.h>
#include <cluster.h>

using namespace gree::flare;

namespace test_cluster
{
	const std::string tmp_dir = "tmp";

	void setup() {
		mkdir(tmp_dir.c_str(), 0700);
	}

	struct cluster_test : public cluster
	{
		cluster_test(std::string data_dir):
			cluster(NULL, data_dir, "localhost", 11211) { }
		~cluster_test() { }

		using cluster::_load;
		using cluster::_save;
		using cluster::_node_map;
		using cluster::_thread_type;
	};

	void test_deserialization_skip() {
		cluster_test cluster(".");
		cut_assert_equal_int(0, cluster._load());
		cut_assert_equal_int(0, cluster._node_map.size());
		cut_assert_equal_int(16, cluster._thread_type);
	}

	void test_deserialization_ok() {
		// Initialization
		const std::string _tmp_dir = tmp_dir + std::string("/cdo");
		mkdir(_tmp_dir.c_str(), 0700);
		std::string flare_xml_contents = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>\n"
			"<!DOCTYPE boost_serialization>\n"
			"<boost_serialization signature=\"serialization::archive\" version=\"7\">\n"
			"<node_map class_id=\"0\" tracking_level=\"0\" version=\"0\">\n"
			"	<count>1</count>\n"
			"	<item_version>0</item_version>\n"
			"	<item class_id=\"1\" tracking_level=\"0\" version=\"0\">\n"
			"		<first>172.16.65.242:13301</first>\n"
			"		<second class_id=\"2\" tracking_level=\"0\" version=\"0\">\n"
			"			<node_server_name>172.16.65.242</node_server_name>\n"
			"			<node_server_port>13301</node_server_port>\n"
			"			<node_role>0</node_role>\n"
			"			<node_state>1</node_state>\n"
			"			<node_partition>2</node_partition>\n"
			"			<node_balance>3</node_balance>\n"
			"			<node_thread_type>4</node_thread_type>\n"
			"		</second>\n"
			"	</item>\n"
			"</node_map>\n"
			"<thread_type>5</thread_type>\n"	// Wrong: thread_type == item.node_thread_type
			"</boost_serialization>\n";
		std::ofstream flare_xml_file(std::string(_tmp_dir + std::string("/flare.xml")).c_str());
		flare_xml_file << flare_xml_contents;
		flare_xml_file.close();
		// Test
		cluster_test cluster(_tmp_dir);
		cut_assert_equal_int(0, cluster._load());
		cut_assert_equal_int(1, cluster._node_map.size());
		cut_assert_equal_string("172.16.65.242:13301", cluster._node_map.begin()->first.c_str());
		cut_assert_equal_string("172.16.65.242", cluster._node_map.begin()->second.node_server_name.c_str());
		cut_assert_equal_int(13301, cluster._node_map.begin()->second.node_server_port);
		cut_assert_equal_int(0, cluster._node_map.begin()->second.node_role);
		cut_assert_equal_int(1, cluster._node_map.begin()->second.node_state);
		cut_assert_equal_int(2, cluster._node_map.begin()->second.node_partition);
		cut_assert_equal_int(3, cluster._node_map.begin()->second.node_balance);
		cut_assert_equal_int(4, cluster._node_map.begin()->second.node_thread_type);
		cut_assert_equal_int(5, cluster._thread_type);
	}

	void test_deserialization_wrong_thread_type() {
		// Initialization
		const std::string _tmp_dir = tmp_dir + std::string("/thread_type");
		mkdir(_tmp_dir.c_str(), 0700);
		std::string flare_xml_contents = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>\n"
			"<!DOCTYPE boost_serialization>\n"
			"<boost_serialization signature=\"serialization::archive\" version=\"7\">\n"
			"<node_map class_id=\"0\" tracking_level=\"0\" version=\"0\">\n"
			"	<count>1</count>\n"
			"	<item_version>0</item_version>\n"
			"	<item class_id=\"1\" tracking_level=\"0\" version=\"0\">\n"
			"		<first>172.16.65.242:13301</first>\n"
			"		<second class_id=\"2\" tracking_level=\"0\" version=\"0\">\n"
			"			<node_server_name>172.16.65.242</node_server_name>\n"
			"			<node_server_port>13301</node_server_port>\n"
			"			<node_role>1</node_role>\n"
			"			<node_state>0</node_state>\n"
			"			<node_partition>0</node_partition>\n"
			"			<node_balance>1</node_balance>\n"
			"			<node_thread_type>80</node_thread_type>\n"
			"		</second>\n"
			"	</item>\n"
			"</node_map>\n"
			"<thread_type>80</thread_type>\n"	// Wrong: thread_type == item.node_thread_type
			"</boost_serialization>\n";
		std::ofstream flare_xml_file(std::string(_tmp_dir + std::string("/flare.xml")).c_str());
		flare_xml_file << flare_xml_contents;
		flare_xml_file.close();
		// Test
		cluster_test cluster(_tmp_dir);
		cut_assert_equal_int(-1, cluster._load());
	}

	void teardown() {
		cut_remove_path(tmp_dir.c_str(), NULL);
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
