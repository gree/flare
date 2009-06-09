/**
 *	client.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __CLIENT_H__
#define __CLIENT_H__

#include "connection.h"
#include "op_get.h"
#include "op_gets.h"
#include "op_add.h"
#include "op_cas.h"

namespace gree {
namespace flare {

typedef class client client;
typedef shared_ptr<client> shared_client;

/**
 *	flare client class
 */
class client {
protected:
	shared_connection		_connection;
	string							_node_server_name;
	int									_node_server_port;

public:
	client(string node_server_name, int node_server_port);
	virtual ~client();

	bool is_available() { return this->_connection->is_available(); };
	int connect();
	int disconnect();

	op::result get(string key, storage::entry& e);
	op::result gets(string key, storage::entry& e);

	op::result add(string key, const char* data, uint64_t data_size, int flag = 0);
	op::result add(string key, int data, int flag = 0);
	op::result cas(string key, const char* data, uint64_t data_size, int flag = 0, uint64_t version = 0);
};

}	// namespace flare
}	// namespace gree

#endif // __CLIENT_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
