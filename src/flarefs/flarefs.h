/**
 *	flarefs.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__FLAREFS_H__
#define	__FLAREFS_H__

#define	FUSE_USE_VERSION	25
#include <fuse.h>

#include "app.h"
#include "ini_option.h"

namespace gree {
namespace flare {

typedef class fuse_impl fuse_impl;

/**
 *	flarefs application class
 */
class flarefs : public app {
private:
	fuse_impl*				_fuse;

public:
	flarefs();
	~flarefs();

	int startup(int argc, char** argv);
	int run();
	int reload();
	int shutdown();

protected:
	string _get_pid_path();

private:
	int _set_resource_limit();
	int _set_signal_handler();
};

}	// namespace flare
}	// namespace gree

#endif	// __FLAREFS_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
