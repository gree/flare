/**
 *	storage.cc
 *
 *	implementation of gree::flare::storage
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "storage.h"

namespace gree {
namespace flare {

// {{{
// }}}

// {{{ ctor/dtor
/**
 *	ctor for storage
 */
storage::storage(string data_dir):
		_open(false),
		_data_dir(data_dir) {
	int i;
	for (i = 0; i < mutex_slot; i++) {
		pthread_rwlock_init(&this->_mutex_slot[i], NULL);
	}
}

/**
 *	dtor for storage
 */
storage::~storage() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int storage::_unserialize_header(const uint8_t* data, int data_len, entry& e) {
	int offset = 0;

	// flag
	if (static_cast<int>(offset + sizeof(e.flag)) > data_len) {
		log_warning("data is smaller than expected header size (member=flag, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.flag));
		return -1;
	}
	memcpy(&e.flag, data+offset, sizeof(e.flag));
	offset += sizeof(e.flag);

	// expire
	if (static_cast<int>(offset + sizeof(e.expire)) > data_len) {
		log_warning("data is smaller than expected header size (member=expire, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.expire));
		return -1;
	}
	memcpy(&e.expire, data+offset, sizeof(e.expire));
	offset += sizeof(e.expire);
	
	// version
	if (static_cast<int>(offset + sizeof(e.version)) > data_len) {
		log_warning("data is smaller than expected header size (member=version, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.version));
		return -1;
	}
	memcpy(&e.version, data+offset, sizeof(e.version));
	offset += sizeof(e.version);
	
	// size
	if (static_cast<int>(offset + sizeof(e.size)) > data_len) {
		log_warning("data is smaller than expected header size (member=size, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.size));
		return -1;
	}
	memcpy(&e.size, data+offset, sizeof(e.size));
	offset += sizeof(e.size);

	log_debug("header: flag=%d, expire=%d, version=%u, size=%u", e.flag, e.expire, e.version, e.size);

	return offset;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
