/**
 *	file_coordinator.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	__FILE_COORDINATOR_H__
#define	__FILE_COORDINATOR_H__

#include <boost/lexical_cast.hpp>
#include <pthread.h>

#include "coordinator.h"

using namespace std;

namespace gree {
namespace flare {

class file_coordinator : public coordinator
{
	pthread_mutex_t				_mutex_file_manipulation;
	uri										_uri;

public:
	file_coordinator(const string& coordinator_uri);
	virtual ~file_coordinator();

	virtual int store_state(const string& flare_xml);
	virtual int restore_state(string& flare_xml);

	string get_scheme()    { return this->_uri.scheme; }
	string get_authority() { return this->_uri.authority; }
	string get_user()      { return this->_uri.user; }
	string get_host()      { return this->_uri.host; }
	int get_port()         { return this->_uri.port; }
	string get_path()      { return this->_uri.path; }

protected:
	int _save(const string& flare_xml);
	int _load(string& flare_xml);
};

}	// namespace flare
}	// namespace gree

#endif	// __FILE_COORDINATOR_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
