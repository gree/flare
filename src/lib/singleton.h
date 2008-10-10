/**
 *	singleton.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef	__SINGLETON_H__
#define	__SINGLETON_H__

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

#endif	// __SINGLETON_H__
// vim: foldmethod=marker tabstop=4 shiftwidth=4 autoindent
