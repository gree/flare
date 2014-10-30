/**
 *	coordinator.h
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 *
 *	$Id$
 */
#ifndef	__COORDINATOR_H__
#define	__COORDINATOR_H__

#include <boost/function.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/regex.hpp>

using namespace std;

namespace gree {
namespace flare {

class coordinator
{
public:
	class operation
	{
		coordinator*		_coord;
	public:
		operation(coordinator *coord)
			: _coord(coord) {
		}
		virtual ~operation() {}
	public:
		coordinator* get_coordinator();
	};
	typedef boost::shared_ptr<operation> shared_operation;

protected:
	struct uri {
		std::string scheme;
		std::string authority;
		std::string user;
		std::string host;
		int         port;
		std::string path;
		std::string query;
		std::string fragment;

		/**
		 *  scheme://[user@][host][:port]/[path][?query][#fragment]
		 */
		uri(std::string s) {
			static const char * pattern = "\\A([^:]+)://" // scheme
				"((?:([^:/@]*)@)?([^:@/]*)(?::(\\d+))?)"   // authority = [user-info@]host[:port]
				"(/[^\\?]*)(?:\\?([^#]*))?(?:#(.*))?\\z";    // body = [path?query#fragment]

			static const boost::regex e(pattern);
			boost::smatch match;
			boost::regex_match(s, match, e);
			this->scheme    = match[1].str();
			this->authority = match[2].str();
			this->user      = match[3].str();
			this->host      = match[4].str();
			this->port      = 0;
			try {
				this->port    = boost::lexical_cast<int>(match[5].str());
			} catch (boost::bad_lexical_cast& e) {
				;
			}
			this->path      = match[6].str();
			this->query     = match[7].str();
			this->fragment  = match[8].str();
		}
	};

protected:
	coordinator();
public:
	virtual ~coordinator();

	virtual int begin_operation(shared_operation& operation, const string& message) { return 0; }
	virtual int end_operation(shared_operation& operation) { return 0; }
	virtual int store_state(const string& flare_xml) = 0;
	virtual int restore_state(string& flare_xml) = 0;
	virtual void set_update_handler(boost::function<void ()> fn) {}
	virtual int get_meta_variables(map<string,string>& variables) {	return 0; }

	int begin_operation(shared_operation& operation) { return begin_operation(operation, ""); }
};

}	// namespace flare
}	// namespace gree

#endif	// __COORDINATOR_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
