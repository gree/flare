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
 *	status.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__STATUS_H__
#define	__STATUS_H__

namespace gree {
namespace flare {

class status {
public:
	enum status_code {
		status_ok,
		status_ng,
	};

protected:
	status_code	_status_code;

public:
	status() : _status_code(status_ok) {};
	virtual ~status() {};

	inline void set_status_code(status_code s) { this->_status_code = s; };
	inline status_code get_status_code() { return this->_status_code; };

	virtual inline const char* get_detail_status() {
		switch (this->_status_code) {
		case status_ok:
			return "";
		case status_ng:
			return "unknown error";
		}
		return "";
	};
};

}	// namespace flare
}	// namespace gree

#endif	// __STATUS_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
