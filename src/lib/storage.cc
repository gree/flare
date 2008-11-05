/**
 *	storage.cc
 *
 *	implementation of gree::flare::storage
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "app.h"
#include "storage.h"

namespace gree {
namespace flare {

// {{{
// }}}

// {{{ ctor/dtor
/**
 *	ctor for storage
 */
storage::storage(string data_dir, int mutex_slot_size):
		_open(false),
		_data_dir(data_dir),
		_mutex_slot_size(mutex_slot_size),
		_mutex_slot(NULL),
		_data_version_cache_map(NULL) {
	this->_mutex_slot = _new_ pthread_rwlock_t[mutex_slot_size];
	int i;
	for (i = 0; i < this->_mutex_slot_size; i++) {
		pthread_rwlock_init(&this->_mutex_slot[i], NULL);
	}

	this->_data_version_cache_map = tcmapnew();
}

/**
 *	dtor for storage
 */
storage::~storage() {
	_delete_(this->_mutex_slot);

	if (this->_data_version_cache_map) {
		tcmapdel(this->_data_version_cache_map);
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
// }}}

// {{{ protected methods
int storage::_serialize_header(entry& e, uint8_t* data) {
	int offset = 0;

	// flag
	memcpy(data+offset, &e.flag, sizeof(e.flag));
	offset += sizeof(e.flag);

	// expire
	memcpy(data+offset, &e.expire, sizeof(e.expire));
	offset += sizeof(e.expire);

	// size
	memcpy(data+offset, &e.size, sizeof(e.size));
	offset += sizeof(e.size);
	
	// version
	memcpy(data+offset, &e.version, sizeof(e.version));
	offset += sizeof(e.version);

	return 0;
}

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
	
	// size
	if (static_cast<int>(offset + sizeof(e.size)) > data_len) {
		log_warning("data is smaller than expected header size (member=size, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.size));
		return -1;
	}
	memcpy(&e.size, data+offset, sizeof(e.size));
	offset += sizeof(e.size);

	// version
	if (static_cast<int>(offset + sizeof(e.version)) > data_len) {
		log_warning("data is smaller than expected header size (member=version, data_len=%d, offset=%d, size=%d)", data_len, offset, sizeof(e.version));
		return -1;
	}
	memcpy(&e.version, data+offset, sizeof(e.version));
	offset += sizeof(e.version);
	
	log_debug("header: flag=%d, expire=%d, version=%u, size=%u", e.flag, e.expire, e.version, e.size);

	return offset;
}

inline int storage::_set_data_version_cache(string key, uint64_t version) {
	uint8_t tmp[sizeof(uint64_t) + sizeof(time_t)];
	uint64_t* p;
	time_t* q;

	p = reinterpret_cast<uint64_t*>(tmp);
	*p = version;
	q = reinterpret_cast<time_t*>(tmp+sizeof(uint64_t));
	*q = stats_object->get_timestamp();

	tcmapput(this->_data_version_cache_map, key.c_str(), key.size(), tmp, sizeof(tmp));

	return 0;
};

int storage::_gc_data_version_cache(int lifetime) {
	log_debug("gc for data version cache (lifetime=%d)", lifetime);

	time_t t_limit = stats_object->get_timestamp() - lifetime;
	tcmapiterinit(this->_data_version_cache_map);
	int key_len;
	char* key;
	while ((key = (char*)tcmapiternext(this->_data_version_cache_map, &key_len)) != NULL) {
		int tmp_len;
		uint8_t* tmp = (uint8_t*)tcmapget(this->_data_version_cache_map, key, key_len, &tmp_len);
		if (tmp == NULL) {
			continue;
		}

		time_t t = *(reinterpret_cast<time_t*>(tmp+sizeof(uint64_t)));
		if (t < t_limit) {
			log_debug("clearing expired data version cache (key=%s, t=%d)", key, t);
			tcmapout(this->_data_version_cache_map, key, key_len);
		}
	}

	return 0;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
