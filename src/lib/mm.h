/**
 *	mm.h
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#ifndef __MM_H__
#define __MM_H__

#ifdef MM_ALLOCATION_CHECK
#include <map>
#include <string>

#include <unistd.h>

using namespace std;

void* operator new(size_t size, const char* file, int line);
void* operator new [](size_t size, const char* file, int line);

namespace gree {
namespace flare {

namespace mm_const {
	static const string dump_dir("/var/tmp");
} // namespace mm_const

#define	_new_ 									new(__FILE__, __LINE__)
#define	_delete_(p)							{ mm::remove_alloc_list(p, __FILE__, __LINE__); delete p; }

/**
 *	memory manager class (just a utility for now...)
 */
class mm {
private:
	typedef struct {
		const void*		addr;
		uint32_t			size;
		char					file[1024];
		int						line;
		char					file_free[1024];
		int						line_free;
		bool					flag;
	} alloc_info;

	typedef map<unsigned int, alloc_info> alloc_list_t;

	static alloc_list_t alloc_list;

public:
	static int add_alloc_list(const void* addr, uint32_t size, const char* file, int line);
	static int remove_alloc_list(const void* addr, const char* file, int line);
	static int dump_alloc_list();
};

}	// namespace flare
}	// namespace gree

#else
# define	_new_				new
# define	_delete_(p)	delete p
#endif

#endif // __MM_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
