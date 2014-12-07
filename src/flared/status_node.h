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
 *	status_node.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__STATUS_NODE_H__
#define	__STATUS_NODE_H__

#include "status.h"
#include "logger.h"

namespace gree {
namespace flare {

class status_node : public status {
public:
	enum node_status_code {
		node_status_ok,
		node_status_storage_error,
		node_status_unknown_error,
	};

protected:
	node_status_code	_node_status_code;

public:
	status_node();
	virtual ~status_node();

	void set_node_status_code(node_status_code s);

	virtual inline const char* get_detail_status() {
		switch (this->_node_status_code) {
		case node_status_ok:
			return "";
		case node_status_storage_error:
			return "storage error";
		case node_status_unknown_error:
			return "unknown error";
		}
		return "";
	}

private:
	inline status_code _get_status_of(node_status_code s) {
		switch (s) {
		case node_status_ok:
			return status_ok;
		case node_status_storage_error:
			return status_ng;
		case node_status_unknown_error:
			return status_ng;
		}
		log_err("node_status_code is unknown value: %d", s);
		return status_ng;
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __STATUS_NODE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
