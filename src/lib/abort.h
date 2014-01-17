/**
 *	abort.h
 *
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */

#ifndef ABORT_H
#define ABORT_H

#include <stdlib.h>

#define ABORT_IF_FAILURE(actual, expect) \
	if (actual != expect) { \
		abort(); \
	}

#endif// ABORT_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
