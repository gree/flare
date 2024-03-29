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
 *	logger.cc
 *	
 *	implementation of gree::flare::logger
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *	
 *	$Id$
 */
#include "logger.h"

namespace gree {
namespace flare {

// {{{ ctor/dtor
/**
 *	ctor for logger
 */
logger::logger():
	_open(false),
	_facility(LOG_USER) {
}

/**
 *	dtor for logger
 */
logger::~logger() {
	if (!this->_log_stderr) {
		closelog();
	}
}
// }}}

// {{{ operator overloads
// }}}

// {{{ public methods
/**
 *	open log procs
 */
int logger::open(string ident, string facility, bool log_stderr) {
	if (this->_open) {
		return -1;
	}

	this->_ident = ident;
	this->_facility = this->_facility_atoi(facility);
	this->_log_stderr = log_stderr;
	if (!this->_log_stderr) {
		openlog(this->_ident.c_str(), LOG_NDELAY|LOG_PID, this->_facility);
	}

	this->_open = true;

	return 0;
}

/**
 *	close log procs
 */
int logger::close() {
	if (this->_open == false) {
		return -1;
	}

	if (!this->_log_stderr) {
		closelog();
	}

	this->_open = false;

	return 0;
}

/**
 *	log message (emerg)
 */
void logger::emerg(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][EMG][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_EMERG, "%s", s.str().c_str());
	}
}

/**
 *	log message (alert)
 */
void logger::alert(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][ALT][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_ALERT, "%s", s.str().c_str());
	}
}

/**
 *	log message (crit)
 */
void logger::crit(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][CRT][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_CRIT, "%s", s.str().c_str());
	}
}

/**
 *	log message (err)
 */
void logger::err(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][ERR][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_ERR, "%s", s.str().c_str());
	}
}

/**
 *	log message (warning)
 */
void logger::warning(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][WRN][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_WARNING, "%s", s.str().c_str());
	}
}

/**
 *	log message (notice)
 */
void logger::notice(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][NTC][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_NOTICE, "%s", s.str().c_str());
	}
}

/**
 *	log message (info)
 */
void logger::info(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][INF][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_INFO, "%s", s.str().c_str());
	}
}

/**
 *	log message (debug)
 */
void logger::debug(const char* file, const int line, const char* func, const char *format, ...) {
	ostringstream s;
	s << "[" << (unsigned long)pthread_self() << "][DBG][" << file << ":" << line << "-" << func << "] ";

	char buf[1024];
	va_list op;
	va_start(op, format);
	vsnprintf(buf, sizeof(buf), format, op);
	va_end(op);
	s << buf;
	if (this->_log_stderr) {
		fprintf(stderr, "%s\n", s.str().c_str());
	} else {
		syslog(LOG_DEBUG, "%s", s.str().c_str());
	}

}
// }}}

// {{{ protected methods
// }}}

// {{{ private methods
/**
 *	convert facility string to system defined intval
 *
 *	@todo	handle invalid facility name(?)
 */
int logger::_facility_atoi(string facility) {
	if (this->_facility_map.empty()) {
		// initialize
		this->_facility_map["auth"]		= LOG_AUTH;
		this->_facility_map["daemon"]	= LOG_DAEMON;
		this->_facility_map["user"]		= LOG_USER;
		this->_facility_map["local0"]	= LOG_LOCAL0;
		this->_facility_map["local1"]	= LOG_LOCAL1;
		this->_facility_map["local2"]	= LOG_LOCAL2;
		this->_facility_map["local3"]	= LOG_LOCAL3;
		this->_facility_map["local4"]	= LOG_LOCAL4;
		this->_facility_map["local5"]	= LOG_LOCAL5;
		this->_facility_map["local6"]	= LOG_LOCAL6;
		this->_facility_map["local7"]	= LOG_LOCAL7;
	}

	return this->_facility_map[facility];
}
// }}}

}	// namespace flare
}	// namespace gree

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
