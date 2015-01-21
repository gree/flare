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
 *	proxy_event_listener.h
 *
 *	@author Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	PROXY_EVENT_LISTENER_H
#define	PROXY_EVENT_LISTENER_H

namespace gree {
namespace flare {

typedef class op_proxy_read op_proxy_read;
typedef class op_proxy_write op_proxy_write;

class proxy_event_listener {
public:
	proxy_event_listener() { }
	virtual ~proxy_event_listener() { }

	virtual int on_pre_proxy_read(op_proxy_read* op) = 0;
	virtual int on_pre_proxy_write(op_proxy_write* op) = 0;
	virtual int on_post_proxy_write(op_proxy_write* op) = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// PROXY_EVENT_LISTENER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
