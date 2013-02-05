/**
 *	ini.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __INI_H__
#define __INI_H__

#include <fstream>
#include <iostream>
#include <string>

#include <boost/program_options.hpp>

#include "config.h"
#include "singleton.h"
#include "logger.h"
#include "util.h"

using namespace std;
using namespace boost;

namespace gree {
namespace flare {

/**
 *	flared configuration base class
 */
class ini {
protected:
	bool			_load;
public:
	ini();
	virtual ~ini();

	virtual int load() = 0;
	virtual int reload() = 0;

	bool is_load() { return this->_load; };
};

}	// namespace flare
}	// namespace gree

#endif // __INI_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
