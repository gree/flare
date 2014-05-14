/**
 *	storage_listener.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__STORAGE_LISTENER_H__
#define __STORAGE_LISTENER_H__

namespace gree {
namespace flare {

class storage_listener {
public:
	virtual void on_storage_error() = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// __STORAGE_LISTENER_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
