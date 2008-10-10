/**
 *	logger.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __LOGGER_H__
#define __LOGGER_H__

#include <iterator>
#include <map>
#include <sstream>
#include <string>
#include <vector>

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
#define	log_emerge(fmt, ...)	logger_singleton::instance().emerge(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#else
#define	log_debug(fmt, ...)
#define	log_info(fmt, ...)
#define	log_notice(fmt, ...)	logger_singleton::instance().notice(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_warning(fmt, ...)	logger_singleton::instance().warning(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_err(fmt, ...)			logger_singleton::instance().err(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_crit(fmt, ...)		logger_singleton::instance().crit(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_alert(fmt, ...)		logger_singleton::instance().alert(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
#define	log_emerge(fmt, ...)	logger_singleton::instance().emerge(__FILE__, __LINE__, __func__, fmt, __VA_ARGS__)
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

public:
	logger();
	virtual ~logger();

	int open(string ident, string facility);
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

#endif // __LOGGER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
