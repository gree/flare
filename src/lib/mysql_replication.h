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
 *	mysql_replication.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef MYSQL_REPLICATION_H
#define MYSQL_REPLICATION_H

#include "connection.h"
#include "thread.h"
#include "queue_proxy_write.h"

#ifdef ENABLE_MYSQL_REPLICATION

namespace gree {
namespace flare {

// include/my_global.h
#define	mysql_int2store(T,A)						*((uint16_t*) (T)) = (uint16_t) (A)
#define	mysql_int3store(T,A)						do { *(T)=  (uint8_t) ((A)); \
																					*(T+1)=(uint8_t) (((uint32_t) (A) >> 8)); \
																					*(T+2)=(uint8_t) (((A) >> 16)); } while (0)
#define	mysql_int4store(T,A)						*((long *) (T)) = (long) (A)

// include/mysql_com.h
#define	MYSQL_NET_HEADER_SIZE						4           // standard header size
#define	MYSQL_CLIENT_LONG_PASSWORD			1						// new more secure passwords
#define	MYSQL_CLIENT_FOUND_ROWS					2						// Found instead of affected rows
#define	MYSQL_CLIENT_LONG_FLAG					4						// Get all column flags
#define	MYSQL_CLIENT_CONNECT_WITH_DB		8						// One can specify db on connect
#define	MYSQL_CLIENT_NO_SCHEMA					16					// Don't allow database.table.column
#define	MYSQL_CLIENT_COMPRESS						32					// Can use compression protocol
#define	MYSQL_CLIENT_ODBC								64					// Odbc client
#define	MYSQL_CLIENT_LOCAL_FILES				128					// Can use LOAD DATA LOCAL
#define	MYSQL_CLIENT_IGNORE_SPACE				256					// Ignore spaces before '('
#define	MYSQL_CLIENT_PROTOCOL_41				512					// New 4.1 protocol
#define	MYSQL_CLIENT_INTERACTIVE				1024				// This is an interactive client
#define	MYSQL_CLIENT_SSL								2048				// Switch to SSL after handshake
#define	MYSQL_CLIENT_IGNORE_SIGPIPE			4096				// IGNORE sigpipes
#define	MYSQL_CLIENT_TRANSACTIONS				8192				// Client knows about transactions
#define	MYSQL_CLIENT_RESERVED         	16384				// Old flag for 4.1 protocol
#define	MYSQL_CLIENT_SECURE_CONNECTION	32768				// New 4.1 authentication
#define	MYSQL_CLIENT_MULTI_STATEMENTS 	(1UL << 16) // Enable/disable multi-stmt suppor
#define	MYSQL_CLIENT_MULTI_RESULTS			(1UL << 17) // Enable/disable multi-results
#define	MYSQL_SERVER_STATUS_IN_TRANS		1        		// Transaction has started
#define	MYSQL_SERVER_STATUS_AUTOCOMMIT	2        		// Server in auto_commit mode
#define	MYSQL_SERVER_STATUS_CURSOR_EXISTS	64
#define	MYSQL_SERVER_STATUS_LAST_ROW_SENT	128
#define	MYSQL_SERVER_STATUS_DB_DROPPED		256				// A database was dropped
#define	MYSQL_SERVER_STATUS_NO_BACKSLASH_ESCAPES	512

// sql/net_serv.cc
#define	MYSQL_MAX_PACKET_LENGTH					(256L*256L*256L-1)

/**
 *	mysql replication class
 */
class mysql_replication {
protected:
	typedef vector<pair<string, int> >	field_vector;

	shared_thread				_thread;
	shared_connection		_connection;

	uint32_t						_server_id;
	string							_database;
	string							_table;

	uint32_t						_packet_id;
	uint32_t						_offset;

public:
	static const int default_protocol_version = 10;
	static const int default_language = 63;					// binary

	mysql_replication(shared_thread t, shared_connection c, uint32_t server_id, string database, string table);
	virtual ~mysql_replication();

	int handshake();
	int parse();
	int send(shared_queue_proxy_write q);

protected:
	int _send_handshake();
	int _send_ok();
	int _send_query_log_event(const char* query, int query_len);
	int _send_result_header(int n);
	int _make_field_packet(char* buf, int buf_len, string name, int type);
	int _send_field_packet(field_vector f);
	int _send_eof();
	int _send_row_1(time_t ts);
	int _send_row_1(const char* p);
	int _send_row_2(const char* p, int n);
	int _recv_handshake();
	int _write(char* buf, int len);
	int _read(char** p);
};

}	// namespace flare
}	// namespace gree

#endif //ENABLE_MYSQL_REPLICATION

#endif // MYSQL_REPLICATION_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
