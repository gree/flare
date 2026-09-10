/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */
/**
 *	op_backup.cc
 *
 *	implementation of gree::flare::op_backup
 */
#include "op_backup.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

// {{{ ctor/dtor
op_backup::op_backup(shared_connection c, storage* st):
		op(c, "backup"),
		_storage(st),
		_backup_name("") {
}

op_backup::~op_backup() {
}
// }}}

// {{{ protected methods
/**
 *	parse server request parameters
 *
 *	syntax:
 *	backup <name>
 */
int op_backup::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[BUFSIZ];
	int n = util::next_word(p, q, sizeof(q));
	if (q[0] == '\0') {
		log_warning("no backup name specified", 0);
		delete[] p;
		return -1;
	}
	this->_backup_name = q;

	// Any extra parameter is tolerated but logged, matching other ops.
	n += util::next_word(p+n, q, sizeof(q));
	if (q[0] != '\0') {
		log_notice("bogus parameter: %s -> ignoring", q);
	}

	delete[] p;
	return 0;
}

int op_backup::_run_server() {
#ifdef HAVE_LIBROCKSDB
	if (!this->_storage || this->_storage->get_type() != storage::type_rocksdb) {
		log_warning("backup requested but storage is not RocksDB", 0);
		return this->_send_result(result_server_error, "not_supported");
	}
	storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
	if (!rdb) {
		return this->_send_result(result_server_error, "internal_error");
	}

	string out_path;
	if (rdb->create_named_backup(this->_backup_name, out_path) < 0) {
		log_warning("backup [%s] failed", this->_backup_name.c_str());
		return this->_send_result(result_server_error, "backup_failed");
	}

	// Emit the checkpoint path as a memcached-flavored STAT line so the
	// client parses it with the same machinery as `stats`/`orphan_scan`.
	char line[BUFSIZ];
	snprintf(line, sizeof(line), "STAT backup_path %s\r\n", out_path.c_str());
	this->_connection->write(line, strlen(line));

	log_notice("backup [%s] complete -> %s", this->_backup_name.c_str(), out_path.c_str());

	return this->_send_result(result_end);
#else
	(void)this->_storage;
	return this->_send_result(result_server_error, "not_compiled");
#endif
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
