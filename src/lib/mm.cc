/**
 *	mm.cc
 *	
 *	implementation of gree::flare::mm
 *
 *	@author	Masaki Fujimoto <fujimoto@php.net>
 *
 *	$Id$
 */
#include "mm.h"

#ifdef MM_ALLOCATION_CHECK
void* operator new(uint32_t size, const char* file, int line) {
	void* p = (void*)malloc(size);
	gree::flare::mm::add_alloc_list(p, size, file, line);

	return p;
}

void* operator new [](uint32_t size, const char* file, int line) {
	void* p = (void*)malloc(size);
	gree::flare::mm::add_alloc_list(p, size, file, line);

	return p;
}

namespace gree {
namespace flare {

mm::alloc_list_t mm::alloc_list;

int mm::add_alloc_list(const void* addr, uint32_t size, const char* file, int line) {
	alloc_info al;
	if (alloc_list.find((uint32_t)addr) != alloc_list.end()) {
	} else {
		alloc_info al = alloc_list[(uint32_t)addr];
		if (al.flag) {
			// double new?
			char log_path[1024];
			snprintf(log_path, sizeof(log_path), "%s/alloc_dn.%d.%d.txt", mm_const::dump_dir.c_str(), getpid(), (int)pthread_self());
			FILE* fp = fopen(log_path, "a");
			fprintf(fp, "%s:%d -> %s:%d:%p\n", al.file, al.line, file, line, addr);
			fclose(fp);
		}
	}
	al.addr = addr;
	al.size = size;
	strncpy(al.file, file, sizeof(al.file));
	al.line = line;
	al.file_free[0] = '\0';
	al.line_free = -1;
	al.flag = true;
	alloc_list[(uint32_t)addr] = al;

	return 0;
}

int mm::remove_alloc_list(const void* addr, const char* file, int line) {
	if (alloc_list.find((uint32_t)addr) == alloc_list.end()) {
		// non-alloc free
		char log_path[1024];
		snprintf(log_path, sizeof(log_path), "%s/alloc_nf.%d.%d.txt", mm_const::dump_dir.c_str(), getpid(), (int)pthread_self());
		FILE* fp = fopen(log_path, "a");
		fprintf(fp, "%s:%d:%p\n", file, line, addr);
		fclose(fp);
	} else {
		if (alloc_list[(uint32_t)addr].flag == false) {
			// double free
			alloc_info al = alloc_list[(uint32_t)addr];
			char log_path[1024];
			snprintf(log_path, sizeof(log_path), "/var/tmp/alloc_nf.%d.%d.txt", getpid(), (int)pthread_self());
			FILE* fp = fopen(log_path, "a");
			fprintf(fp, "%s:%d -> %s:%d -> %s:%d:%p\n", al.file, al.line, al.file_free, al.line_free, file, line, addr);
			fclose(fp);
		}
		strncpy(alloc_list[(uint32_t)addr].file_free, file, sizeof(alloc_list[(uint32_t)addr].file_free));
		alloc_list[(uint32_t)addr].line_free = line;
		alloc_list[(uint32_t)addr].flag = false;
	}
	return 0;
}

int mm::dump_alloc_list() {
	char log_path[1024];
	snprintf(log_path, sizeof(log_path), "%s/alloc_leak.%d.%d.txt", mm_const::dump_dir.c_str(), getpid(), (int)pthread_self());
	FILE* fp = fopen(log_path, "a");

	map<uint32_t, alloc_info>::iterator it;
	for (it = alloc_list.begin(); it != alloc_list.end(); it++) {
		if (it->second.flag == false) {
			continue;
		}
#if 0
		char buf[256];
		memset(buf, 0, sizeof(buf));
		memcpy(buf, it->second.addr, it->second.size < (sizeof(buf)-1) ? it->second.size : sizeof(buf)-1);
		fprintf(fp, "%s:%d:%p:%s\n", it->second.file, it->second.line, it->second.addr, buf);
#else
		fprintf(fp, "%s:%d:%p\n", it->second.file, it->second.line, it->second.addr);
#endif
	}

	fclose(fp);

	return 0;
}

}	// namespace flare
}	// namespace gree

#endif	// MM_ALLOCATION_CHECK
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
