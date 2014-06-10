#ifndef	STORAGE_ENGINE_FACTORY_H
#define	STORAGE_ENGINE_FACTORY_H

#include <stdint.h>

#include "storage_engine_tcb.h"
#include "storage_engine_tch.h"
#ifdef HAVE_LIBKYOTOCABINET
#include "storage_engine_kch.h"
#endif
#include "logger.h"

namespace gree {
namespace flare {

class storage_engine_factory {
public:
	static storage_engine_interface* create(
		string storage_type,
		string data_dir,
		uint32_t storage_ap,
		uint32_t storage_fp,
		uint64_t storage_bucket_size,
		string storage_compress,
		bool storage_large,
		int storage_lmemb,
		int storage_nmemb,
		int32_t storage_dfunit,
		storage_listener* listener
	) {
		storage::type t = storage::type_tch;
		storage::type_cast(ini_option_object().get_storage_type(), t);
		switch (t) {
		case storage::type_tcb:
			return new storage_engine_tcb(
				data_dir,
				storage_ap,
				storage_fp,
				storage_bucket_size,
				storage_compress,
				storage_large,
				storage_lmemb,
				storage_nmemb,
				storage_dfunit,
				listener
			);
		case storage::type_tch:
			return new storage_engine_tch(
				data_dir,
				storage_ap,
				storage_fp,
				storage_bucket_size,
				storage_compress,
				storage_large,
				storage_dfunit,
				listener
			);
#ifdef HAVE_LIBKYOTOCABINET
		case storage::type_kch:
			return new storage_engine_kch(
				data_dir,
				storage_ap,
				storage_bucket_size,
				storage_compress,
				storage_large,
				storage_dfunit,
				listener
			);
#endif
		default:
			log_err("unknown storage type [%s]", storage_type.c_str());
			return NULL;
		}
	}
};

}	// namespace flare
}	// namespace gree

#endif
