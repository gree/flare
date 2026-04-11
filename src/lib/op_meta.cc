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
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *	op_meta.cc
 *
 *	implementation of gree::flare::op_meta
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "op_meta.h"
#include "key_resolver_modular.h"
#ifdef HAVE_LIBROCKSDB
#include "storage_rocksdb.h"
#endif

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for op_meta
 */
op_meta::op_meta(shared_connection c, cluster* cl, storage* st):
		op(c, "meta"),
		_cluster(cl),
		_storage(st),
		_meta_key("") {
}

/**
 *	dtor for op_meta
 */
op_meta::~op_meta() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	send client request
 */
int op_meta::run_client(int& partition_size, storage::hash_algorithm& key_hash_algorithm, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual) {
	if (this->_run_client() < 0) {
		return -1;
	}

	return this->_parse_text_client_parameters(partition_size, key_hash_algorithm, key_resolver_type, key_resolver_modular_hint, key_resolver_modular_virtual);
}

/**
 *	send client features request
 */
int op_meta::run_client_features(bool& rocksdb_wal_supported) {
	string ignored;
	return this->run_client_features(rocksdb_wal_supported, ignored);
}

int op_meta::run_client_features(bool& rocksdb_wal_supported, string& master_id) {
	if (this->_run_client_features() < 0) {
		return -1;
	}

	return this->_parse_text_client_features(rocksdb_wal_supported, master_id);
}
// }}}

// {{{ protected methods
/**
 *	parser server request parameters
 *
 *	syntax:
 *	META [features]
 */
int op_meta::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}

	char q[1024];
	int n = util::next_word(p, q, sizeof(q));
	if (q[0]) {
		// Check if it's "features"
		if (strcmp(q, "features") == 0) {
			this->_meta_key = "features";
			// No more arguments expected
			n += util::next_word(p+n, q, sizeof(q));
			if (q[0]) {
				log_debug("bogus string(s) found after 'features' [%s] -> error", q);
				delete[] p;
				return -1;
			}
		} else {
			// Unknown parameter
			log_debug("unknown parameter [%s] -> error", q);
			delete[] p;
			return -1;
		}
	}
	// else: empty means cluster metadata request (backward compat)

	delete[] p;

	return 0;
}

int op_meta::_run_server() {
	// Check if this is a features request
	if (this->_meta_key == "features") {
		// Capability negotiation for RocksDB WAL replication
#ifdef HAVE_LIBROCKSDB
		if (this->_storage && this->_storage->get_type() == storage::type_rocksdb) {
			// Include the master identity token so a reconstructing
			// peer can adopt it after its own op_dump completes —
			// without this hook, every subsequent WAL sync would trip
			// master_id_mismatch and force a redundant full dump.
			storage_rocksdb* rdb = dynamic_cast<storage_rocksdb*>(this->_storage);
			if (rdb) {
				string reply = "rocksdb_wal=1 master_id=" + rdb->get_master_id();
				return this->_send_result(result_ok, reply.c_str());
			}
			return this->_send_result(result_ok, "rocksdb_wal=1");
		}
#endif
		// RocksDB not available or not enabled - return ERROR
		return this->_send_result(result_error);
	}

	// Original cluster metadata response
	ostringstream s;
	char buf[BUFSIZ];

	// partition size
	snprintf(buf, sizeof(buf), "META partition-size %d", this->_cluster->get_partition_size());
	s << buf << line_delimiter;

	// hash algorithm
	snprintf(buf, sizeof(buf), "META key-hash-algorithm %s",
					 storage::hash_algorithm_cast(this->_cluster->get_key_hash_algorithm()).c_str());
	s << buf << line_delimiter;

	// partition type
	key_resolver* kr = this->_cluster->get_key_resolver();
	snprintf(buf, sizeof(buf), "META partition-type %s", key_resolver::type_cast(kr->get_type()).c_str());
	s << buf << line_delimiter;

	// partition modular hint|virtual
	if (kr->get_type() == key_resolver::type_modular) {
		key_resolver_modular* krm = dynamic_cast<key_resolver_modular*>(kr);
		if (krm) {
			snprintf(buf, sizeof(buf), "META partition-modular-hint %d", krm->get_hint());
			s << buf << line_delimiter;

			snprintf(buf, sizeof(buf), "META partition-modular-virtual %d", krm->get_virtual());
			s << buf << line_delimiter;
		} else {
			log_err("keyresolver dynamic cast failed", 0);
		}
	}

	this->_connection->write(s.str().c_str(), s.str().size());

	return this->_send_result(result_end);
}

int op_meta::_run_client() {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "meta");
	return this->_send_request(request);
}

int op_meta::_run_client_features() {
	char request[BUFSIZ];
	snprintf(request, sizeof(request), "meta features");
	return this->_send_request(request);
}

int op_meta::_parse_text_client_parameters(int& partition_size, storage::hash_algorithm& key_hash_algorithm, key_resolver::type& key_resolver_type, int& key_resolver_modular_hint, int& key_resolver_modular_virtual) {
	for (;;) {
		char* p;
		if (this->_connection->readline(&p) < 0) {
			log_err("something is going wrong while node add request", 0);
			return -1;
		}
		if (strcmp(p, "END\n") == 0) {
			delete[] p;
			break;
		}

		char q[BUFSIZ];
		try {
			int i = util::next_word(p, q, sizeof(q));
			if (strcmp(q, "META") != 0) {
				log_warning("unknown first token [%s]", q);
				throw -1;
			}

			// meta key
			i += util::next_word(p+i, q, sizeof(q));
			if (q[0] == '\0') {
				log_warning("no meta key (required)", 0);
				throw -1;
			}

			// value(s)
			if (strcmp(q, "partition-size") == 0) {
				i += util::next_digit(p+i, q, sizeof(q));
				if (q[0] == '\0') {
					log_warning("no partition size value (required)", 0);
					throw -1;
				}
				partition_size = boost::lexical_cast<int>(q);
				log_debug("meta: key=[%s] value=[%d]", "partition-size", partition_size);
			} else if (strcmp(q, "key-hash-algorithm") == 0) {
				i += util::next_word(p+i, q, sizeof(q));
				if (storage::hash_algorithm_cast(q, key_hash_algorithm) < 0) {
					log_warning("meta: key=[%s] value=[%d]", "key-hash-algorithm", key_hash_algorithm);
					throw -1;
				}
				log_debug("meta: key=[%s] value=[%s]", "key-hash-algorithm", q);
			} else if (strcmp(q, "partition-type") == 0) {
				i += util::next_word(p+i, q, sizeof(q));
				if (key_resolver::type_cast(q, key_resolver_type) < 0) {
					log_warning("unknown partition type [%s]", q);
					throw -1;
				}
				log_debug("meta: key=[%s] value=[%s]", "partition-type", q);
			} else if (strcmp(q, "partition-modular-hint") == 0) {
				i += util::next_digit(p+i, q, sizeof(q));
				if (q[0] == '\0') {
					log_warning("no hint value (required)", 0);
					throw -1;
				}
				key_resolver_modular_hint = boost::lexical_cast<int>(q);
				log_debug("meta: key=[%s] value=[%d]", "partition-modular-hint", key_resolver_modular_hint);
			} else if (strcmp(q, "partition-modular-virtual") == 0) {
				i += util::next_digit(p+i, q, sizeof(q));
				if (q[0] == '\0') {
					log_warning("no hint value (required)", 0);
					throw -1;
				}
				key_resolver_modular_virtual = boost::lexical_cast<int>(q);
				log_debug("meta: key=[%s] value=[%d]", "partition-modular-virtual", key_resolver_modular_virtual);
			} else {
				log_warning("unknown meta key [%s]", q);
				throw -2;
			}

			i += util::next_word(p+i, q, sizeof(q));
			if (q[0] != '\0') {
				log_notice("bogus parameter: %s -> ignoring", q);
			}
		} catch (boost::bad_lexical_cast e) {
			log_warning("invalid digit [%s]", e.what());
		} catch (int e) {
			if (e == -2) {
				log_warning("error occured while parsing response -> skip this line", 0);
			} else {
				delete[] p;
				return -1;
			}
		}

		delete[] p;
	}

	return 0;
}

int op_meta::_parse_text_client_features(bool& rocksdb_wal_supported, string& master_id) {
	rocksdb_wal_supported = false;
	master_id.clear();

	// Read response line
	char* p;
	if (this->_connection->readline(&p) < 0) {
		log_err("failed to read features response", 0);
		return -1;
	}

	// Expected form:
	//   OK rocksdb_wal=1 master_id=<uuid>\r\n
	//   OK rocksdb_wal=1\r\n     (older server)
	//   ERROR\r\n                (feature unavailable)
	char q[BUFSIZ];
	int i = util::next_word(p, q, sizeof(q));

	if (strcmp(q, "OK") == 0) {
		// Walk through remaining tokens. We accept them in any order.
		while (true) {
			int consumed = util::next_word(p+i, q, sizeof(q));
			if (q[0] == '\0') break;
			i += consumed;
			if (strcmp(q, "rocksdb_wal=1") == 0) {
				rocksdb_wal_supported = true;
			} else if (strncmp(q, "master_id=", 10) == 0) {
				master_id.assign(q + 10);
			} else {
				log_debug("unknown features token [%s]", q);
			}
		}
		if (rocksdb_wal_supported) {
			log_info("master supports RocksDB WAL replication (master_id=%s)", master_id.c_str());
		}
		delete[] p;
		return 0;
	} else if (strcmp(q, "ERROR") == 0) {
		// Master doesn't support features or doesn't have RocksDB
		log_info("master does not support RocksDB WAL replication", 0);
		delete[] p;
		return 0;
	} else {
		log_warning("unexpected response to meta features: %s", q);
		delete[] p;
		return -1;
	}
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
