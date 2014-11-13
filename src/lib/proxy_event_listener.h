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
