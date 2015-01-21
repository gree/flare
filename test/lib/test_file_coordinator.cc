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
 *	test-file-coordinator.cc
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 */

#include <sys/stat.h>
#include <sys/types.h>

#include <cppcutter.h>

#include <file_coordinator.h>

using namespace std;
using namespace gree::flare;

namespace test_file_coordinator {

	void setup() {
	}

	void teardown() {
	}

	void check(file_coordinator& fc, const char* scheme = "", const char* authority = "",
						 const char* user = "", const char* host = "", const int port = 0,
						 const char* path = "/") {
		cut_assert_equal_string(scheme, fc.get_scheme().c_str());
		cut_assert_equal_string(host, fc.get_host().c_str());
		cppcut_assert_equal(port, fc.get_port());
		cut_assert_equal_string(path, fc.get_path().c_str());
#if 0
		cout << "scheme=\"" << fc.get_scheme() << "\", "
				 << "host=\"" << fc.get_host() << "\", "
				 << "port=\"" << fc.get_port() << "\""
				 << "path=\"" << fc.get_path() << "\""
				 << endl;
#endif
	}

	void test_scheme_dot() {
		file_coordinator fc_dot("file://./");
		check(fc_dot, "file", "", "", ".", 0, "/");
	}

	void test_scheme_local() {
		file_coordinator fc_local("file://./var/run/flare/flare.xml");
		check(fc_local, "file", "", "", ".", 0, "/var/run/flare/flare.xml");
	}

	void test_scheme_emptyhost() {
		file_coordinator fc_emptyhost("file:///var/run/flare/flare.xml");
		check(fc_emptyhost, "file", "", "", "", 0, "/var/run/flare/flare.xml");
	}

}
