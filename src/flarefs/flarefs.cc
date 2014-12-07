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
 *	flarefs.cc
 *
 *	implementation of gree::flare::flarefs (and some other global stuffs)
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "flarefs.h"
#include "fuse_impl.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for flarefs
 */
flarefs::flarefs():
		_fuse(NULL) {
}

/**
 *	dtor for flarefs
 */
flarefs::~flarefs() {
	delete this->_fuse;
	this->_fuse = NULL;

	delete stats_object;
	stats_object = NULL;
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	flarefs application startup procs
 */
int flarefs::startup(int argc, char **argv) {
	ini_option_object().set_args(argc, argv);
	if (ini_option_object().load() < 0) {
		return -1;
	}

	singleton<logger>::instance().open(this->_ident, ini_option_object().get_log_facility());
	stats_object = new stats();
	stats_object->startup();

	log_notice("%s version %s - system logger started", this->_ident.c_str(), PACKAGE_VERSION);

	log_notice("application startup in progress...", 0);
	log_notice("  chunk_size:             %d", ini_option_object().get_chunk_size());
	log_notice("  config_path:            %s", ini_option_object().get_config_path().c_str());
	log_notice("  connection_pool_size    %d", ini_option_object().get_connection_pool_size());
	log_notice("  data_dir:               %s", ini_option_object().get_data_dir().c_str());
	log_notice("  fuse_allow_other:       %s", ini_option_object().is_fuse_allow_other() ? "true" : "false");
	log_notice("  fuse_allow_root:        %s", ini_option_object().is_fuse_allow_root() ? "true" : "false");
	log_notice("  mount_dir:              %s", ini_option_object().get_mount_dir().c_str());
	log_notice("  node_server_name:       %s", ini_option_object().get_node_server_name().c_str());
	log_notice("  node_server_port:       %d", ini_option_object().get_node_server_port());

	// startup procs
	if (this->_set_resource_limit() < 0) {
		return -1;
	}

	if (this->_set_signal_handler() < 0) {
		return -1;
	}

	// application objects
	this->_fuse = new fuse_impl(ini_option_object().get_mount_dir());
	this->_fuse->set_allow_other(ini_option_object().is_fuse_allow_other());
	this->_fuse->set_allow_root(ini_option_object().is_fuse_allow_root());

	if (this->_set_pid() < 0) {
		return -1;
	}

	return 0;
}

/**
 *	flarefs application running loop
 */
int flarefs::run() {
	log_notice("entering running loop", 0);

	this->_fuse->run();

	return 0;
}

/**
 *	flarefs application reload procs
 */
int flarefs::reload() {
	if (ini_option_object().reload() < 0) {
		log_notice("invalid config file -> skip reloading", 0);
		return -1;
	}

	// log_facility
	log_notice("re-opening syslog...", 0);
	singleton<logger>::instance().close();
	singleton<logger>::instance().open(this->_ident, ini_option_object().get_log_facility()); 

	log_notice("process successfully reloaded", 0);

	return 0;
}

/**
 *	flarefs application shutdown procs
 */
int flarefs::shutdown() {
	this->_clear_pid();

	return 0;
}
// }}}

// {{{ protected methods
string flarefs::_get_pid_path() {
	return ini_option_object().get_data_dir() + "/" + this->_ident + ".pid";
};
// }}}

// {{{ private methods
/**
 *	set resource limit
 */
int flarefs::_set_resource_limit() {
	return 0;
}

/**
 *	setup signal handler(s)
 */
int flarefs::_set_signal_handler() {
	return 0;
}
// }}}

}	// namespace flare
}	// namespace gree

// {{{ ::main (entry point)
int main(int argc, char **argv) {
	gree::flare::flarefs& f = gree::flare::singleton<gree::flare::flarefs>::instance();
	f.set_ident("flarefs");

	if (f.startup(argc, argv) < 0) {
		return -1;
	}
	int r = f.run();
	f.shutdown();

	return r;
}
// }}}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
