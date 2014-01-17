/**
 *	file_coordinator.cc
 *
 *	implementation of gree::flare::file_coordinator
 *
 *	@author Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fstream>

#include "abort.h"
#include "util.h"
#include "file_coordinator.h"

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster
 */
file_coordinator::file_coordinator(const string& coordinator_uri)
	: _uri(coordinator_uri) {
	ABORT_IF_FAILURE(pthread_mutex_init(&this->_mutex_file_manipulation, NULL), 0);
	if (this->get_scheme() != "file") {
		log_warning("invalid scheme [%s]", this->get_scheme().c_str());
	}
}

/**
 *	dtor for cluster
 */
file_coordinator::~file_coordinator() {
	;
}
// }}}

// {{{ public methods
int file_coordinator::store_state(const string& flare_xml) {
	return this->_save(flare_xml);
}

int file_coordinator::restore_state(string& flare_xml) {
	return this->_load(flare_xml);
}
// }}}

// {{{ protected methods
/**
 *	save node variables
 */
int file_coordinator::_save(const string& flare_xml) {
	string path = this->get_path() + "/flare.xml";
	string path_tmp = path + ".tmp";

	pthread_mutex_lock(&this->_mutex_file_manipulation);

	ofstream ofs(path_tmp.c_str());
	if (ofs.fail()) {
		log_err("creating serialization file failed -> daemon restart will cause serious problem (path=%s)", path_tmp.c_str());
		pthread_mutex_unlock(&this->_mutex_file_manipulation);
		return -1;
	}

	ofs << flare_xml;
	ofs.close();

	if (unlink(path.c_str()) < 0 && errno != ENOENT) {
		pthread_mutex_unlock(&this->_mutex_file_manipulation);
		log_err("unlink() for current serialization file failed (%s)", util::strerror(errno));
		return -1;
	}
	if (rename(path_tmp.c_str(), path.c_str()) < 0) {
		pthread_mutex_unlock(&this->_mutex_file_manipulation);
		log_err("rename() for current serialization file failed (%s)", util::strerror(errno));
		return -1;
	}

	pthread_mutex_unlock(&this->_mutex_file_manipulation);
	return 0;
}

/**
 *	load node variables
 */
int file_coordinator::_load(string& flare_xml) {
	ostringstream oss;
	string path = this->get_path() + "/flare.xml";

	pthread_mutex_lock(&this->_mutex_file_manipulation);

	try {
		ifstream ifs(path.c_str());
		if (ifs.fail()) {
			struct stat st;
			if (::stat(path.c_str(), &st) < 0 && errno == ENOENT) {
				log_info("no such entry -> skip unserialization [%s]", path.c_str());
				throw 0;
			} else {
				log_err("opening serialization file failed -> daemon restart will cause serious problem (path=%s)", path.c_str());
			}
			throw -1;
		}
		
		char ch;
		while(ifs.get(ch)) {
			oss.put(ch);
		}
		if (!ifs.eof()) {
			log_info("failed to read [%s]", path.c_str());
			throw -1;
		}
		ifs.close();
	} catch(int ret) {
		pthread_mutex_unlock(&this->_mutex_file_manipulation);
		return ret;
	}

	pthread_mutex_unlock(&this->_mutex_file_manipulation);
	flare_xml = oss.str();
	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
