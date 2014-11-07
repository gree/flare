/**
 *	storage_listener.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	STORAGE_LISTENER_H
#define STORAGE_LISTENER_H

namespace gree {
namespace flare {

class storage_listener {
public:
	virtual void on_storage_error() = 0;
};

}	// namespace flare
}	// namespace gree

#endif	// STORAGE_LISTENER_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
