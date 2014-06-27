#ifndef	STORAGE_ENGINE_TCB_H
#define	STORAGE_ENGINE_TCB_H

#include "storage_engine_interface.h"
#include "storage_listener.h"
#include "tcutil.h"
#include "tcbdb.h"

namespace gree {
namespace flare {

class storage_engine_tcb : public storage_engine_interface {
protected:
	bool									_iter_first;
	bool									_open;
	string								_data_dir;
	storage_listener*			_listener;
	BDBCUR*								_cursor;
	string								_data_path;
	TCBDB*								_db;

public:
	storage_engine_tcb(string data_dir, uint32_t storage_ap, uint32_t storage_fp, uint64_t storage_bucket_size, string storage_compess, bool storage_large, int storage_lmemb, int storage_nmemb, int32_t storage_dfunit, storage_listener* listener);
	virtual ~storage_engine_tcb();
	virtual int open();
	virtual int close();
	virtual int set(storage::entry& e, const uint8_t* data, const int data_len);
	virtual uint8_t* get(const string& key, int& data_len);
	virtual int remove(const string& key);
	virtual int truncate();
	virtual int iter_begin();
	virtual storage::iteration iter_next(string& key);
	virtual int iter_end();
	virtual uint32_t count();
	virtual uint64_t size();
	virtual bool is_get_with_buffer_support();
	virtual int get_with_buffer(const string& key, uint8_t* buffer, const int max_size);
	virtual bool is_get_volatile_support();
	virtual const uint8_t* get_volatile(const string& key, int& data_len);
	virtual bool is_prefix_search_support();
	virtual int get_key_list_with_prefix(const string& prefix, int limit, vector<string>& r);
};

}	// namespace flare
}	// namespace gree

#endif
