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
 *	mysql_replication.cc
 *	
 *	implementation of gree::flare::mysql_replication
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "app.h"
#include "storage.h"
#include "mysql_replication.h"

#ifdef ENABLE_MYSQL_REPLICATION

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for mysql_replication
 */
mysql_replication::mysql_replication(shared_thread t, shared_connection c, uint32_t server_id, string database, string table):
		_thread(t),
		_connection(c),
		_server_id(server_id),
		_database(database),
		_table(table),
		_packet_id(0),
		_offset(0) {
}

/**
 *	dtor for mysql_replication
 */
mysql_replication::~mysql_replication() {
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
int mysql_replication::handshake() {
	log_debug("handshake process is in progress...", 0);

	if (this->_send_handshake() < 0) {
		return -1;
	}
	if (this->_recv_handshake() < 0) {
		return -1;
	}
	if (this->_send_ok() < 0) {
		return -1;
	}

	return 0;
}

int mysql_replication::parse() {
	char* p;
	int r = 0;

	for (;;) {
		int len = this->_read(&p);
		if (len < 0) {
			return -1;
		}
		log_debug("command accepted: %d (parameter=%s)", *p, len > 1 ? p+1 : "");

		// just for replication
		//   - wait for COM_QUIT | COM_BINLOG_DUMP
		//   - handle specific sql(s) only
		if (*p == 1 || *p == 18) {
			if (*p == 1) {
				r = -1;
			}
			break;
		} else if (*p == 3) {
			if (strncasecmp(p+1, "SELECT UNIX_TIMESTAMP()", len-1) == 0) {
				this->_send_result_header(1);

				field_vector f;
				pair<string, int> p("UNIX_TIMESTAMP()", 0x07);
				f.push_back(p);
				this->_send_field_packet(f);

				this->_send_eof();
				this->_send_row_1(stats_object->get_timestamp());
				this->_send_eof();
			} else if (strncasecmp(p+1, "select @@version_comment limit 1", len-1) == 0) {
				this->_send_result_header(1);

				field_vector f;
				pair<string, int> p("@@version_comment", 0xfe);
				f.push_back(p);
				this->_send_field_packet(f);

				this->_send_eof();
				this->_send_row_1("served by replication dedicated thread");
				this->_send_eof();
			} else if (strncasecmp(p+1, "SHOW VARIABLES LIKE 'SERVER_ID'", len-1) == 0) {
				this->_send_result_header(2);

				field_vector f;
				pair<string, int> p("Variable_name", 0xfe);
				f.push_back(p);
				p.first = "Value";
				p.second = 0x03;
				f.push_back(p);
				this->_send_field_packet(f);

				this->_send_eof();
				this->_send_row_2("server_id", 8);
				this->_send_eof();
			} else if (strncasecmp(p+1, "SHOW SLAVE HOSTS", len-1) == 0) {
				this->_send_result_header(5);

				field_vector f;
				pair<string, int> p("Server_id", 0x03);
				f.push_back(p);
				p.first = "Host";
				p.second = 0xfe;
				f.push_back(p);
				p.first = "Port";
				p.second = 0x03;
				f.push_back(p);
				p.first = "Rpl_recovery_rank";
				p.second = 0x03;
				f.push_back(p);
				p.first = "Master_id";
				p.second = 0x03;
				f.push_back(p);

				this->_send_field_packet(f);
				this->_send_eof();
				this->_send_eof();
			} else if (strncasecmp(p+1, "SET NAMES", strlen("SET NAMES")) == 0) {
				this->_send_ok();
			}
		}
		delete[] p;
		p = NULL;
	}
	if (p) {
		delete[] p;
	}

	return r;
}

int mysql_replication::send(shared_queue_proxy_write q) {
	log_debug("ready to send binlog entry (ident=%s)", q->get_ident().c_str());
	if (q->is_post_proxy() == false) {
		log_debug("queue is not post proxied -> skip replication", 0);
		return 0;
	}

	string op_ident = q->get_op_ident();
	storage::entry& e = q->get_entry();

	// FIXME: design fixes
	int query_size = BUFSIZ + e.key.size() + e.size*2;
	int query_len = 0;
	char* query = new char[BUFSIZ + e.key.size() + e.size*2];
	if (op_ident != "delete") {
		query_len = snprintf(query, query_size, "REPLACE INTO `%s` VALUES ('%s', '", this->_table.c_str(), e.key.c_str());

		char* from = reinterpret_cast<char*>(e.data.get());
		char* to = query + query_len;
		for (int i = 0; i < static_cast<int>(e.size); i++) {
			char escape = 0;
			switch (*(from+i)) {
			case 0:
				escape = '0';
				break;
			case '\n':              /* Must be escaped for logs */
				escape= 'n';
				break;
			case '\r':
				escape= 'r';
				break;
			case '\\':
				escape= '\\';
				break;
			case '\'':
				escape= '\'';
				break;
			case '"':               /* Better safe than sorry */
				escape= '"';
				break;
			case '\032':            /* This gives problems on Win32 */
				escape= 'Z';
				break;
			}
			if (escape) {
				*to++ = '\\';
				*to++ = escape;
			} else {
				*to++ = *(from+i);
			}
		}
		query_len = to-query;

		query_len += snprintf(query+query_len, query_size-query_len, "', %u, %llu, ", e.flag, e.version);
		if (e.expire > 0) {
			struct tm t;
			localtime_r(&(e.expire), &t);
			query_len += snprintf(query+query_len, query_size-query_len, "'%04d-%02d-%02d %02d:%02d:%02d')", t.tm_year+1900, t.tm_mon+1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec);
		} else {
			query_len += snprintf(query+query_len, query_size-query_len, "0)");
		}
	} else {
		query_len = snprintf(query, query_size, "DELETE FROM `%s` WHERE k='%s'", this->_table.c_str(), e.key.c_str());
	}
	if (this->_send_query_log_event(query, query_len) < 0) {
		delete[] query;
		return -1;
	}
	delete[] query;

	return 0;
}
// }}}

// {{{ protected methods
int mysql_replication::_send_handshake() {
	uint8_t buf[BUFSIZ];
	int len = 0;
	memset(buf, 0, sizeof(buf));

	// protocol version
	*(buf+len) = mysql_replication::default_protocol_version;
	len++;

	// server version (version emuration...)
	len += snprintf(reinterpret_cast<char*>(buf+len), sizeof(buf)-len, "%s-%s-%s", "5.0.23", PACKAGE_NAME, PACKAGE_VERSION) + 1;

	// therad id
	mysql_int4store(buf+len, this->_thread->get_id());
	len += 4;

	// scampble buf (do not care about here)
	len += 8;

	// filler
	len += 1;

	// server capability
	len += 2;

	// server language
	*(buf+len) = mysql_replication::default_language;
	len += 1;

	// server status
	mysql_int2store(buf+len, MYSQL_SERVER_STATUS_AUTOCOMMIT);
	len += 2;

	// filler
	len += 13;

	// additional scrampble buf
	len += 13;

	log_debug("sending handshake packet (%d bytes)", len);
	if (this->_write(reinterpret_cast<char*>(buf), len) != len) {
		return -1;
	}

	return 0;
}

int mysql_replication::_send_ok() {
	uint8_t buf[BUFSIZ];
	int len = 0;
	memset(buf, 0, sizeof(buf));

	// field count(0) + affected rows(0) + insert id(0)
	len += 3;

	// server status
	mysql_int2store(buf+len, MYSQL_SERVER_STATUS_AUTOCOMMIT);
	len += 2;

	// warning count
	len += 2;

	log_debug("sending ok packet (%d bytes)", len);
	if (this->_write(reinterpret_cast<char*>(buf), len) != len) {
		return -1;
	}

	return 0;
}

int mysql_replication::_send_query_log_event(const char* query, int query_len) {
	int buf_size = BUFSIZ + query_len;
	char* buf = new char[buf_size];
	int len = 0;
	memset(buf, 0, sizeof(buf));

	// magic
	len++;

	// timestamp
	mysql_int4store(buf+len, stats_object->get_timestamp());
	len += 4;

	// type code
	buf[len++] = 2;

	// server id
	mysql_int4store(buf+len, this->_server_id);
	len += 4;

	// event length
	int event_len = 19 + 13 + this->_database.size() + 1 + query_len;
	mysql_int4store(buf+len, event_len);
	len += 4;

	// next position
	this->_offset += event_len;
	mysql_int4store(buf+len, this->_offset);
	len += 4;

	// flags
	mysql_int2store(buf+len, 0);
	len += 2;

	// thread id
	mysql_int4store(buf+len, this->_thread->get_id());
	len += 4;

	// query time
	mysql_int4store(buf+len, 0);
	len += 4;

	// database len
	buf[len++] = this->_database.size();

	// error code
	mysql_int2store(buf+len, 0);
	len += 2;

	// status block len
	mysql_int2store(buf+len, 0);
	len += 2;

	// database
	len += snprintf(buf+len, sizeof(buf)-len, "%s", this->_database.c_str()) + 1;

	// query
	memcpy(buf+len, query, query_len);
	len += query_len;

	if (this->_write(buf, len) != len) {
		delete[] buf;
		return -1;
	}
	delete[] buf;

	return 0;
}

int mysql_replication::_send_result_header(int n) {
	char buf[BUFSIZ];
	buf[0] = n;

	if (this->_write(buf, 1) != 1) {
		return -1;
	}

	return 0;
}

int mysql_replication::_make_field_packet(char* buf, int buf_len, string name, int type) {
	int len = 0;
	memset(buf, 0, buf_len);

	// catalog
	buf[len++] = 3;
	len += snprintf(buf+len, buf_len-len, "%s", "def");
	
	// db, table, org_table
	len += 3;

	// name
	buf[len++] = name.size();
	len += snprintf(buf+len, buf_len-len, "%s", name.c_str());

	// org_name
	len += 1;

	// filler
	buf[len++] = '\x0c';

	// charsetnr
	mysql_int2store(buf+len, mysql_replication::default_language);
	len += 2;

	// length
	mysql_int4store(buf+len, 11);
	len += 4;

	// type
	buf[len++] = type;

	// flag, decimal, filler
	len += 5;

	return len;
}

int mysql_replication::_send_field_packet(vector<pair<string, int> > f) {
	char buf[BUFSIZ];
	int len = 0;

	for (field_vector::iterator it = f.begin(); it != f.end(); it++) {
		len += this->_make_field_packet(buf+len, sizeof(buf)-len, it->first, it->second);
	}

	if (this->_write(buf, len) != len) {
		return -1;
	}

	return 0;
}

int mysql_replication::_send_eof() {
	char buf[BUFSIZ];
	int len = 0;
	memset(buf, 0, sizeof(buf));

	// field count
	buf[len++] = 0xfe;

	// warning count, server status
	len += 4;

	if (this->_write(buf, len) != len) {
		return -1;
	}

	return 0;
}

int mysql_replication::_send_row_1(time_t ts) {
	char buf[BUFSIZ];
	int len = 0;

	int tmp = snprintf(buf+1, sizeof(buf)-1, "%ld", ts);
	buf[len++] = tmp;
	len += tmp;

	if (this->_write(buf, len) != len) {
		return -1;
	}

	return 0;
}

int mysql_replication::_send_row_1(const char* p) {
	char buf[BUFSIZ];
	int len = 0;

	int tmp = snprintf(buf+1, sizeof(buf)-1, "%s", p);
	buf[len++] = tmp;
	len += tmp;

	if (this->_write(buf, len) != len) {
		return -1;
	}

	return 0;
}

int mysql_replication::_send_row_2(const char* p, int n) {
	char buf[BUFSIZ];
	int len = 0;

	int tmp = snprintf(buf+1, sizeof(buf)-1, "%s", p);
	buf[len++] = tmp;
	len += tmp;

	tmp = snprintf(buf+len+1, sizeof(buf)-len-1, "%d", n);
	buf[len++] = tmp;
	len += tmp;

	if (this->_write(buf, len) != len) {
		return -1;
	}

	return 0;
}

int mysql_replication::_recv_handshake() {
	char* p;
	if (this->_read(&p) < 0) {
		return -1;
	}

	// nop

	delete[] p;

	return 0;
}

int mysql_replication::_write(char* buf, int len) {
	char header[MYSQL_NET_HEADER_SIZE];
	int offset = 0;

	while (len > 0) {
		int actual_len = len > MYSQL_MAX_PACKET_LENGTH ? MYSQL_MAX_PACKET_LENGTH : len;
		mysql_int3store(header, actual_len);
		header[3] = static_cast<uint8_t>(this->_packet_id);
		this->_packet_id++;

		if (this->_connection->write(header, MYSQL_NET_HEADER_SIZE, true) != sizeof(header)) {
			return -1;
		}
		if (this->_connection->write(buf+offset, actual_len) != (actual_len + MYSQL_NET_HEADER_SIZE)) {
			return -1;
		}

		len -= actual_len;
		offset += actual_len;
	}

	log_debug("packet size (write) = %d", offset);

	return offset;
}

int mysql_replication::_read(char** p) {
	char *header;

	if (this->_connection->readsize(MYSQL_NET_HEADER_SIZE, &header) != MYSQL_NET_HEADER_SIZE) {
		return -1;
	}

	int len = (header[2] << 16) | (header[1] << 8) | header[0];
	log_debug("packet size=%d, packet id=%d", len, header[3]);
	if (header[3] != static_cast<uint8_t>(this->_packet_id)) {
		log_debug("non sequential packaet id (not sequential?) (recv=%d, current=%d)", header[3], this->_packet_id);
		this->_packet_id = header[3];
	}
	this->_packet_id++;

	delete[] header;

	if (this->_connection->readsize(len, p) != len) {
		return -1;
	}

	return len;
}
// }}}

// {{{ private methods
// }}}

}	// namespace flare
}	// namespace gree

#endif // ENABLE_MYSQL_REPLICATION

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
