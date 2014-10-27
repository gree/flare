/**
 *	ini.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef INI_H
#define INI_H

#include <fstream>
#include <iostream>
#include <string>

#include <boost/program_options.hpp>

#include "config.h"
#include "singleton.h"
#include "logger.h"
#include "util.h"

using namespace std;

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

#endif // INI_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
