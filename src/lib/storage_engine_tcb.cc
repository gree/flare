#include "storage_engine_tcb.h"

namespace gree {
namespace flare {

storage_engine_tcb::storage_engine_tcb(string data_dir, uint32_t storage_ap, uint32_t storage_fp, uint64_t storage_bucket_size, string storage_compess, bool storage_large, int storage_lmemb, int storage_nmemb, int32_t storage_dfunit, storage_listener* listener):
	_iter_first(false),
	_open(false),
	_data_dir(data_dir),
	_listener(listener),
	_cursor(NULL) {

	this->_data_path = this->_data_dir + "/flare.bdb";

	this->_db = tcbdbnew();
	tcbdbsetmutex(this->_db);
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
	tcbdbtune(this->_db, storage_lmemb, storage_nmemb, storage_bucket_size, storage_ap, storage_fp, n);

	if (storage_dfunit > 0) {
		tcbdbsetdfunit(this->_db, storage_dfunit);
	}
}

storage_engine_tcb::~storage_engine_tcb() {
	if (this->_open) {
		this->close();
	}
	if (this->_db != NULL) {
		tcbdbdel(this->_db);
	}
}

int storage_engine_tcb::open() {
	if (this->_open) {
		log_warning("storage has been already opened", 0);
		return -1;
	}

	if (tcbdbopen(this->_db, this->_data_path.c_str(), HDBOWRITER | HDBOCREAT) == false) {
		int ecode = tcbdbecode(this->_db);
		log_err("tcbdbopen() failed: %s (%d)", tcbdberrmsg(ecode), ecode);
		return -1;
	}

	log_debug("storage open (path=%s, type=tcb)", this->_data_path.c_str());
	this->_open = true;

	return 0;
}

int storage_engine_tcb::close() {
	if (this->_open == false) {
		log_warning("storage is not yet opened", 0);
		return -1;
	}

	if (tcbdbclose(this->_db) == false) {
		int ecode = tcbdbecode(this->_db);
		log_err("tcbdbclose() failed: %s (%d)", tcbdberrmsg(ecode), ecode);
		return -1;
	}

	log_debug("storage close", 0);
	this->_open = false;

	return 0;
}

int storage_engine_tcb::set(storage::entry& e, const uint8_t* data, const int data_len) {
	if (tcbdbput(this->_db, e.key.c_str(), e.key.size(), data, data_len) != true) {
		int ecode = tcbdbecode(this->_db);
		log_err("tcbdbput() failed: %s (%d)", tcbdberrmsg(ecode), ecode);
		this->_listener->on_storage_error();
		return -1;
	}
	return 0;
}

uint8_t* storage_engine_tcb::get(const string& key, int& data_len) {
	return reinterpret_cast<uint8_t *>(tcbdbget(this->_db, key.c_str(), key.size(), &data_len));
}

int storage_engine_tcb::remove(const string& key) {
	if (tcbdbout(this->_db, key.c_str(), key.size()) != true) {
		int ecode = tcbdbecode(this->_db);
		log_err("tcbdbout() failed: %s (%d)", tcbdberrmsg(ecode), ecode);
		this->_listener->on_storage_error();
		return -1;
	}
	return 0;
}

int storage_engine_tcb::truncate() {
	if (tcbdbvanish(this->_db) == false) {
		int ecode = tcbdbecode(this->_db);
		log_err("tcbdbvanish() failed: %s (%d)", tcbdberrmsg(ecode), ecode);
		return -1;
	}
	return 0;
}

int storage_engine_tcb::iter_begin() {
	this->_cursor = tcbdbcurnew(this->_db);
	this->_iter_first = true;
	return 0;
}

storage::iteration storage_engine_tcb::iter_next(string& key) {
	if (this->_iter_first) {
		tcbdbcurfirst(this->_cursor);
		this->_iter_first = false;
	} else {
		tcbdbcurnext(this->_cursor);
	}
	int len = 0;
	char* p = static_cast<char*>(tcbdbcurkey(this->_cursor, &len));
	if (p == NULL) {
		int ecode = tcbdbecode(this->_db);
		if (ecode == TCESUCCESS || ecode == TCENOREC) {
			// end of iteration
			return storage::iteration_end;
		} else {
			log_err("iter_next() failed: %s (%d)", tcbdberrmsg(ecode), ecode);
			return storage::iteration_error;
		}
	}
	key = p;
	free(p);

	return storage::iteration_continue;
}

int storage_engine_tcb::iter_end() {
	tcbdbcurdel(this->_cursor);
	return 0;
}

uint32_t storage_engine_tcb::count() {
	return tcbdbrnum(this->_db);
}

uint64_t storage_engine_tcb::size() {
	return tcbdbfsiz(this->_db);
}

bool storage_engine_tcb::is_get_with_buffer_support() {
	return false;
}

int storage_engine_tcb::get_with_buffer(const string& key, uint8_t* buffer, const int max_size){
	return -1;
}

bool storage_engine_tcb::is_get_volatile_support() {
	return true;
}

const uint8_t* storage_engine_tcb::get_volatile(const string& key, int& data_len) {
	return static_cast<const uint8_t*>(tcbdbget3(this->_db, key.c_str(), key.size(), &data_len));
}

bool storage_engine_tcb::is_prefix_search_support() {
	return true;
}

int storage_engine_tcb::get_key_list_with_prefix(const string& prefix, int limit, vector<string>& r) {
	TCLIST* key_list = tcbdbfwmkeys(this->_db, prefix.c_str(), prefix.size(), limit);

	int i;
	for (i = 0; i < tclistnum(key_list); i++) {
		int n;
		const char* p = static_cast<const char*>(tclistval(key_list, i, &n));
		if (p == NULL) {
			break;
		}
		string tmp_key = p;
		r.push_back(tmp_key);
	}

	tclistdel(key_list);

	return 0;
}

}	// namespace flare
}	// namespace gree
