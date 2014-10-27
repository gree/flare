/**
 *	coordinator_factory.cc
 *
 *	implementation of gree::flare::coordinator_factory
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */

#include "coordinator_factory.h"

#include "file_coordinator.h"

#ifdef HAVE_LIBZOOKEEPER_MT
# include "zookeeper_coordinator.h"
#endif

#include <boost/regex.hpp>

namespace gree {
namespace flare {

// {{{ global functions
// }}}

// {{{ ctor/dtor
/**
 *	ctor for cluster
 */
coordinator_factory::coordinator_factory() {
#ifdef HAVE_LIBZOOKEEPER_MT
# ifdef DEBUG
	zoo_set_debug_level(ZOO_LOG_LEVEL_DEBUG);
	this->_log_stream = NULL;
# else
	zoo_set_debug_level(ZOO_LOG_LEVEL_ERROR);
	this->_log_stream = fopen("/dev/null", "w");
	if (this->_log_stream != NULL) {
		zoo_set_log_stream(this->_log_stream);
	}
# endif
#endif
}

/**
 *	dtor for cluster
 */
coordinator_factory::~coordinator_factory() {
#ifdef HAVE_LIBZOOKEEPER_MT
# ifndef DEBUG
	if (this->_log_stream != NULL) {
		fclose(this->_log_stream);
		this->_log_stream = NULL;
	}
# endif
#endif
}
// }}}

// {{{ public methods
coordinator* coordinator_factory::create_coordinator(const string& identifier, const string& myname) {
	const char* pattern = "\\A([^:]+)://.+\\z";
	static const boost::regex e(pattern);

	boost::smatch match;
	boost::regex_match(identifier, match, e);
	string scheme = match[1];

	try {
		if (scheme == "file") {
			return new file_coordinator(identifier);
#ifdef HAVE_LIBZOOKEEPER_MT
		} else if (scheme == "zookeeper") {
			zookeeper_coordinator* zc = new zookeeper_coordinator(identifier, myname);
			if (zc->setup() < 0) {
				delete zc;
			} else {
				return zc;
			}
#endif
		}
	} catch (bad_alloc& e) {
		return NULL;
	} catch (...) {
		return NULL;
	}

	return NULL;
}

void coordinator_factory::destroy_coordinator(coordinator* coord) {
	delete coord;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
