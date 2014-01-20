/**
 *	singleton.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	SINGLETON_H
#define	SINGLETON_H

namespace gree {
namespace flare {

/**
 *	template class to add singleton feature
 */
template <class T>
class singleton {
private:
	singleton();
	singleton(singleton const&);
	singleton& operator=(singleton const&);
	virtual ~singleton();

public:
	static T& instance() {
		static T obj;
		return obj;
	};
};

}	// namespace flare
}	// namespace gree

#endif	// SINGLETON_H
// vim: foldmethod=marker tabstop=4 shiftwidth=4 autoindent
