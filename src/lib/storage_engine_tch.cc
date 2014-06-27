#include "storage_engine_tch.h"

namespace gree {
namespace flare {

storage_engine_tch::storage_engine_tch(string data_dir, uint32_t storage_ap, uint32_t storage_fp, uint64_t storage_bucket_size, string storage_compess, bool storage_large, int32_t storage_dfunit, storage_listener* listener):
	_open(false),
	_data_dir(data_dir),
	_listener(listener) {

	this->_data_path = this->_data_dir + "/flare.hdb";

	this->_db = tchdbnew();
	tchdbsetmutex(this->_db);
	storage::compress t = storage::compress_none;
	storage::compress_cast(storage_compess, t);
	int n = 0;
	if (storage_large) {
		n |= HDBTLARGE;
	}
	switch (t) {
	case storage::compress_none:
		break;
	case storage::compress_deflate:
		n |= HDBTDEFLATE;
		break;
	case storage::compress_bz2:
		n |= HDBTBZIP;
		break;
	case storage::compress_tcbs:
		n |= HDBTTCBS;
		break;
	}
	tchdbtune(this->_db, storage_bucket_size, storage_ap, storage_fp, n);

	if (storage_dfunit > 0) {
		tchdbsetdfunit(this->_db, storage_dfunit);
	}
}

storage_engine_tch::~storage_engine_tch() {
	if (this->_open) {
		this->close();
	}
	if (this->_db != NULL) {
		tchdbdel(this->_db);
	}
}

int storage_engine_tch::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	if (tchdbopen(this->_db, this->_data_path.c_str(), HDBOWRITER | HDBOCREAT) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbopen() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}

	log_debug("storage open (path=%s, type=tch)", this->_data_path.c_str());
	this->_open = true;

	return 0;
}

int storage_engine_tch::close() {
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

int storage_engine_tch::set(storage::entry& e, const uint8_t* data, const int data_len) {
	if (e.option & storage::option_noreply) {
		if (tchdbputasync(this->_db, e.key.c_str(), e.key.size(), data, data_len) != true) {
			int ecode = tchdbecode(this->_db);
			log_err("tchdbputasync() failed: %s (%d)", tchdberrmsg(ecode), ecode);
			this->_listener->on_storage_error();
			return -1;
		}
	} else {
		if (tchdbput(this->_db, e.key.c_str(), e.key.size(), data, data_len) != true) {
			int ecode = tchdbecode(this->_db);
			log_err("tchdbput() failed: %s (%d)", tchdberrmsg(ecode), ecode);
			this->_listener->on_storage_error();
			return -1;
		}
	}
	return 0;
}

uint8_t* storage_engine_tch::get(const string& key, int& data_len) {
	return (uint8_t*)tchdbget(this->_db, key.c_str(), key.size(), &data_len);
}

int storage_engine_tch::remove(const string& key) {
	if (tchdbout(this->_db, key.c_str(), key.size()) != true) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbout() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		this->_listener->on_storage_error();
		return -1;
	}
	return 0;
}

int storage_engine_tch::truncate() {
	if (tchdbvanish(this->_db) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbvanish() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}
	return 0;
}

int storage_engine_tch::iter_begin() {
	if (tchdbiterinit(this->_db) == false) {
		int ecode = tchdbecode(this->_db);
		log_err("tchdbiterinit() failed: %s (%d)", tchdberrmsg(ecode), ecode);
		return -1;
	}
	return 0;
}

storage::iteration storage_engine_tch::iter_next(string& key) {
	int len = 0;
	char* p = static_cast<char*>(tchdbiternext(this->_db, &len));
	if (p == NULL) {
		int ecode = tchdbecode(this->_db);
		if (ecode == TCESUCCESS || ecode == TCENOREC) {
			// end of iteration
			return storage::iteration_end;
		} else {
			log_err("tchdbiternext() failed: %s (%d)", tchdberrmsg(ecode), ecode);
			return storage::iteration_error;
		}
	}
	key = p;
	free(p);

	return storage::iteration_continue;
}

int storage_engine_tch::iter_end() {
	return 0;
}

uint32_t storage_engine_tch::count() {
	return tchdbrnum(this->_db);
}

uint64_t storage_engine_tch::size() {
	return tchdbfsiz(this->_db);
}

bool storage_engine_tch::is_get_with_buffer_support() {
	return true;
}

/**
 * return length
 */
int storage_engine_tch::get_with_buffer(const string& key, uint8_t* buffer, const int max_size){
	return tchdbget3(this->_db, key.c_str(), key.size(), buffer, max_size);
}

bool storage_engine_tch::is_get_volatile_support() {
	return false;
}

const uint8_t* storage_engine_tch::get_volatile(const string& key, int& data_len) {
	return NULL;
}

bool storage_engine_tch::is_prefix_search_support() {
	return false;
}

int storage_engine_tch::get_key_list_with_prefix(const string& prefix, int limit, vector<string>& r) {
	return -1;
}

}	// namespace flare
}	// namespace gree
