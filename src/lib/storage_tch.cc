/**
 *	storage_tch.cc
 *
 *	implementation of gree::flare::storage_tch
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "storage_tch.h"

namespace gree {
namespace flare {

// {{{
// }}}

// {{{ ctor/dtor
/**
 *	ctor for storage_tch
 */
storage_tch::storage_tch(string data_dir):
		storage(data_dir) {
	this->_data_path = this->_data_dir + "/flare.hdb";

	this->_db = tchdbnew();
	tchdbsetmutex(this->_db);
}

/**
 *	dtor for storage
 */
storage_tch::~storage_tch() {
	if (this->_open) {
		this->close();
	}
	if (this->_db != NULL) {
		tchdbdel(this->_db);
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int storage_tch::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	if (tchdbopen(this->_db, this->_data_path.c_str(), HDBOWRITER | HDBOCREAT) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbopen() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}

	log_debug("storage open (path=%s, type=%s)", this->_data_path.c_str(), storage::type_cast(this->_type).c_str());
	this->_open = true;

	return 0;
}

int storage_tch::close() {
	if (this->_open == false) {
		log_warning("storage is not yet opened", 0);
		return -1;
	}

	if (tchdbclose(this->_db) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbclose() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}

	log_debug("storage close", 0);
	this->_open = false;

	return 0;
}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
