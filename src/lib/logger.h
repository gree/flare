/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 * Copyright (C) zakar <zgmfzaku@163.com>
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
 *	logger.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef LOGGER_H
#define LOGGER_H

#include <iterator>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include <stdio.h>
#include <stdarg.h>
#include <syslog.h>

#include "singleton.h"

using namespace std;

namespace gree {
namespace flare {

// followings are a little bit costy but frequency would not be so high, so that we take convenience:)
#ifdef DEBUG
#define	log_debug(fmt, ...)		logger_singleton::instance().debug(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_info(fmt, ...)		logger_singleton::instance().info(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_notice(fmt, ...)	logger_singleton::instance().notice(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_warning(fmt, ...)	logger_singleton::instance().warning(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_err(fmt, ...)			logger_singleton::instance().err(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_crit(fmt, ...)		logger_singleton::instance().crit(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_alert(fmt, ...)		logger_singleton::instance().alert(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_emerg(fmt, ...)		logger_singleton::instance().emerg(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#else
#define	log_debug(fmt, ...)		do {} while(0)
#define	log_info(fmt, ...)		do {} while(0)
#define	log_notice(fmt, ...)	logger_singleton::instance().notice(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_warning(fmt, ...)	logger_singleton::instance().warning(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_err(fmt, ...)			logger_singleton::instance().err(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_crit(fmt, ...)		logger_singleton::instance().crit(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_alert(fmt, ...)		logger_singleton::instance().alert(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_emerg(fmt, ...)	logger_singleton::instance().emerg(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#endif	// DEBUG

#define	logger_object()		logger_singleton::instance()

typedef class logger logger;
typedef singleton<logger> logger_singleton;

/**
 *	logging class
 *
 *	no abstraction, *nix only (this will do for a while:)
 */
class logger {
private:
	bool							_open;
	string						_ident;
	int								_facility;
	map<string, int>	_facility_map;
	bool							_log_stderr;

public:
	logger();
	virtual ~logger();

	int open(string ident, string facility, bool log_stderr);
	int close();

	string get_ident() { return this->_ident; };
	int get_facility() { return this->_facility; };

	void emerg(const char* file, const int line, const char* func, const char *format, ...);
	void alert(const char* file, const int line, const char* func, const char *format, ...);
	void crit(const char* file, const int line, const char* func, const char *format, ...);
	void err(const char* file, const int line, const char* func, const char *format, ...);
	void warning(const char* file, const int line, const char* func, const char *format, ...);
	void notice(const char* file, const int line, const char* func, const char *format, ...);
	void info(const char* file, const int line, const char* func, const char *format, ...);
	void debug(const char* file, const int line, const char* func, const char *format, ...);

private:
	int _facility_atoi(string facility);
};

}	// namespace flare
}	// namespace gree

#endif // LOGGER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
