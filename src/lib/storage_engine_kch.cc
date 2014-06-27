#include "storage_engine_kch.h"

using namespace kyotocabinet;

namespace gree {
namespace flare {

storage_engine_kch::storage_engine_kch(string data_dir, uint32_t storage_ap, uint64_t storage_bucket_size, string storage_compress, bool storage_large, int32_t storage_dfunit, storage_listener* listener):
	_iter_first(false),
	_open(false),
	_data_dir(data_dir),
	_listener(listener),
	_cursor(NULL) {

	this->_data_path = this->_data_dir + "/flare.kch";

	this->_db = new HashDB;
	storage::compress t = storage::compress_none;
	storage::compress_cast(storage_compress, t);

	int tune_options = HashDB::TLINEAR;

	if (!storage_large) {
		tune_options |= HashDB::TSMALL;
	}

	this->_db->tune_buckets(storage_bucket_size);
	this->_db->tune_alignment(storage_ap);
	this->_db->tune_fbp(10);

	if (t != storage::compress_none) {
		tune_options |= HashDB::TCOMPRESS;
		this->_db->tune_compressor(&this->_comp);
	}

	this->_db->tune_options(tune_options);

	if (storage_dfunit > 0) {
		this->_db->tune_defrag(storage_dfunit);
	}
}

storage_engine_kch::~storage_engine_kch() {
	if (this->_open) {
		this->close();
	}
	delete this->_db;
	this->_db = NULL;
}

int storage_engine_kch::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	if (!this->_db->open(this->_data_path, HashDB::OCREATE | HashDB::OWRITER)) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)","HashDB::open()", error.message(), error.code());
		return -1;
	}

	log_debug("storage open (path=%s, type=kch)", this->_data_path.c_str());
	this->_open = true;

	return 0;
}

int storage_engine_kch::close() {
	if (this->_open == false) {
		log_warning("storage is not yet opened", 0);
		return -1;
	}

	if (!this->_db->close()) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)","HashDB::close()", error.message(), error.code());
		return -1;
	}

	log_debug("storage close", 0);
	this->_open = false;

	return 0;
}

int storage_engine_kch::set(storage::entry& e, const uint8_t* data, const int data_len) {
	if (!this->_db->set(e.key.c_str(), e.key.size(), reinterpret_cast<const char*>(data), data_len)) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)", "HashDB::set()", error.message(), error.code());
		this->_listener->on_storage_error();
		return -1;
	}

	if (e.option & storage::option_noreply) {
		log_debug("stored data [async] (key=%s, size=%llu)", e.key.c_str(), data_len);
	} else {
		if (!this->_db->synchronize()) {
			BasicDB::Error error = this->_db->error();
			log_err("%s failed: %s (%d)", "HashDB::synchronize()", error.message(), error.code());
			return -1;
		}
		log_debug("stored data [sync] (key=%s, size=%llu)", e.key.c_str(), data_len);
	}
	return 0;
}

uint8_t* storage_engine_kch::get(const string& key, int& data_len) {
	size_t tmp_data_len = 0;
	uint8_t* data = reinterpret_cast<uint8_t *>(this->_db->get(key.c_str(), key.size(), &tmp_data_len));
	data_len = static_cast<int>(tmp_data_len);
	return data;
}

int storage_engine_kch::remove(const string& key) {
	if (!this->_db->remove(key)) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)","HashDB::remove()", error.message(), error.code());
		this->_listener->on_storage_error();
		return -1;
	}
	return 0;
}

int storage_engine_kch::truncate() {
	if (!this->_db->clear()) {
		BasicDB::Error error = this->_db->error();
		log_err("%s failed: %s (%d)", "HashDB::clear()", error.message(), error.code());
		return -1;
	}
	return 0;
}

int storage_engine_kch::iter_begin() {
	this->_cursor = this->_db->cursor();
	this->_iter_first = true;
	return 0;
}

storage::iteration storage_engine_kch::iter_next(string& key) {
	if (this->_iter_first) {
		this->_cursor->jump();
		this->_iter_first = false;
	} else {
		this->_cursor->step();
	}
	if (!this->_cursor->get_key(&key)) {
		BasicDB::Error error = this->_db->error();
		//When db is empty
		if (error.code() == BasicDB::Error::NOREC) {
			return storage::iteration_end;
		} else {
			log_err("storage_kch::iter_next() failed: %s (%d)", error.message(), error.code());
			return storage::iteration_error;
		}
	}

	return storage::iteration_continue;
}

int storage_engine_kch::iter_end() {
	delete this->_cursor;
	this->_cursor = NULL;
	return 0;
}

uint32_t storage_engine_kch::count() {
	return this->_db->count();
}

uint64_t storage_engine_kch::size() {
	return this->_db->size();
}

bool storage_engine_kch::is_get_with_buffer_support() {
	return true;
}

/**
 * return length
 */
int storage_engine_kch::get_with_buffer(const string& key, uint8_t* buffer, const int max_size){
	return this->_db->get(key.c_str(), key.size(), reinterpret_cast<char *>(buffer), max_size);
}

bool storage_engine_kch::is_get_volatile_support() {
	return false;
}

const uint8_t* storage_engine_kch::get_volatile(const string& key, int& data_len) {
	return NULL;
}

bool storage_engine_kch::is_prefix_search_support() {
	return false;
}

int storage_engine_kch::get_key_list_with_prefix(const string& prefix, int limit, vector<string>& r) {
	return -1;
}

}	// namespace flare
}	// namespace gree
