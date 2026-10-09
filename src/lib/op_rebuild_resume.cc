/**
 *	op_rebuild_resume.cc
 *
 *	implementation of gree::flare::op_rebuild_resume (see the header)
 */
#include "op_rebuild_resume.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

op_rebuild_resume::op_rebuild_resume(shared_connection c, storage* st):
		op(c, "rebuild_resume"),
		_storage(st) {
}

op_rebuild_resume::~op_rebuild_resume() {
}

int op_rebuild_resume::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	delete[] p;
	return 0;
}

int op_rebuild_resume::_run_server() {
#ifdef HAVE_LIBROCKSDB
	storage_rocksdb* rdb = this->_storage ? dynamic_cast<storage_rocksdb*>(this->_storage) : NULL;
	if (rdb == NULL) {
		return this->_send_result(result_server_error, "not_supported");
	}
	const bool was = rdb->resume_rebuild();
	char line[BUFSIZ];
	snprintf(line, sizeof(line), "STAT rebuild_resumed %d\r\n", was ? 1 : 0);
	this->_connection->write(line, strlen(line));
	return this->_send_result(result_end);
#else
	(void)this->_storage;
	return this->_send_result(result_server_error, "not_compiled");
#endif
}

}	// namespace flare
}	// namespace gree
