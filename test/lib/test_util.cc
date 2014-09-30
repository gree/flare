/**
 *	test_util.cc
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 */

#include <cppcutter.h>
#include <pthread.h>

#include <errno.h>
#include <app.h>
#include <util.h>

#if defined(__APPLE__) && defined(__MACH__)
#	define YIELD pthread_yield_np();
#else
#	define YIELD pthread_yield();
#endif

#if (defined(__unix__) || defined(unix)) && !defined(USG)
#	include <sys/param.h>
#endif
#ifdef BSD
#	define ENODATA ENOMSG
#	define ENOSR ENOMSG
#	define ENOSTR ENOMSG
#	define ETIME ETIMEDOUT
#endif

using namespace std;
using namespace gree::flare;

namespace test_util
{
	static int errnos[] = {
		E2BIG, EACCES, EADDRINUSE, EADDRNOTAVAIL, EAFNOSUPPORT, EAGAIN, EALREADY, EBADF, EBADMSG, EBUSY, ECANCELED, ECHILD, ECONNABORTED,
		ECONNREFUSED, ECONNRESET, EDEADLK, EDESTADDRREQ, EDOM, EDQUOT, EEXIST, EFAULT, EFBIG, EHOSTUNREACH, EIDRM, EILSEQ, EINPROGRESS,
		EINTR, EINVAL, EIO, EISCONN, EISDIR, ELOOP, EMFILE, EMLINK, EMSGSIZE, EMULTIHOP, ENAMETOOLONG, ENETDOWN, ENETRESET, ENETUNREACH,
		ENFILE, ENOBUFS, ENODATA, ENODEV, ENOENT, ENOEXEC, ENOLCK, ENOLINK, ENOMEM, ENOMSG, ENOPROTOOPT, ENOSPC, ENOSR, ENOSTR, ENOSYS,
		ENOTCONN, ENOTDIR, ENOTEMPTY, /*ENOTRECOVERABLE,*/ ENOTSOCK, ENOTSUP, ENOTTY, ENXIO, EOPNOTSUPP, EOVERFLOW, /*EOWNERDEAD,*/ EPERM, EPIPE,
		EPROTO, EPROTONOSUPPORT, EPROTOTYPE, ERANGE, EROFS, ESPIPE, ESRCH, ESTALE, ETIME, ETIMEDOUT, ETXTBSY, EWOULDBLOCK, EXDEV, 0
	};

	static std::map<int,string> strerror_expected;

	void setup()
	{
		for (int no = 0; errnos[no] != 0; no++) {
			strerror_expected[errnos[no]] = strerror(errnos[no]);
		}
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	void teardown()
	{
		strerror_expected.clear();
		delete stats_object;
	}

	void* strerror_thread(void *data) {
		CutTestContext *test_context = (CutTestContext *)data;
		cut_set_current_test_context(test_context);

		int j = 0;
		for (int i = 0; i < 1000; i++) {
			if (errnos[j] == 0) {
				j = 0;
			}
			const char *ptr = util::strerror(errnos[j]);
			YIELD;
			string error = ptr;
			cut_assert_equal_string(strerror_expected[errnos[j]].c_str(), error.c_str());
			j++;
		}
		return NULL;
	}

	void test_strerror_mt()
	{
		const int nthreads = 10;
		pthread_t threads[nthreads];
		for(int i = 0; i < nthreads; i++) {
			pthread_create(&threads[i], NULL, strerror_thread, cut_get_current_test_context());
		}
		for(int i = 0; i < nthreads; i++) {
			pthread_join(threads[i], (void**)NULL);
		}
	}

	void test_fqdn()
	{
		string fqdn;
		util::get_fqdn(fqdn);
	}

	void* fqdn_thread(void *data) {
		CutTestContext *test_context = (CutTestContext *)data;
		cut_set_current_test_context(test_context);
		string before, after;

		for (int i = 0; i < 1000; i++) {
			util::get_fqdn(before);
			YIELD;
			util::get_fqdn(after);
			cut_assert_equal_string(before.c_str(), after.c_str());
		}
		return NULL;
	}

	void test_fqdn_mt()
	{
		const int nthreads = 10;
		pthread_t threads[nthreads];
		for(int i = 0; i < nthreads; i++) {
			pthread_create(&threads[i], NULL, fqdn_thread, cut_get_current_test_context());
		}
		for(int i = 0; i < nthreads; i++) {
			pthread_join(threads[i], (void**)NULL);
		}
	}

	void test_inet_addr()
	{
		cut_assert_equal_int(static_cast<in_addr_t>(htonl(0x00000000)),
												util::inet_addr("12.34.56.78", htonl(0x00000000)));
		cut_assert_equal_int(static_cast<in_addr_t>(htonl(0x0c22384e)),
												util::inet_addr("12.34.56.78", htonl(0xffffffff)));
		cut_assert_equal_int(static_cast<in_addr_t>(htonl(0x0c223000)),
												util::inet_addr("12.34.56.78", htonl(0xfffff000)));
		for (int sh = 1; sh <= 32; sh++) {
			cut_assert_equal_int(static_cast<in_addr_t>(htonl(0x0c22384e & (0xffffffff << sh))),
													util::inet_addr("12.34.56.78", htonl(0xffffffff << sh)));
		}
	}

	void test_gethostbyname_localhost_name() {
		sockaddr_in output;
		int gai_errno;
		cut_assert_equal_int(0, util::gethostbyname("localhost", 12121, AF_INET, output, gai_errno));
		cut_assert_equal_int(0, gai_errno);
		cut_assert_equal_int(AF_INET, output.sin_family);
		cut_assert_equal_int(12121, ntohs(output.sin_port));
		in_addr reference;
		inet_aton("127.0.0.1", &reference);
		cut_assert_equal_memory(&reference.s_addr, sizeof(reference), &output.sin_addr.s_addr, sizeof(reference));
	}

	void test_gethostbyname_localhost_address() {
		sockaddr_in output;
		int gai_errno;
		cut_assert_equal_int(0, util::gethostbyname("127.0.0.1", 12121, AF_INET, output, gai_errno));
		cut_assert_equal_int(0, gai_errno);
		cut_assert_equal_int(AF_INET, output.sin_family);
		cut_assert_equal_int(12121, ntohs(output.sin_port));
		in_addr reference;
		inet_aton("127.0.0.1", &reference);
		cut_assert_equal_memory(&reference.s_addr, sizeof(reference), &output.sin_addr.s_addr, sizeof(reference));
	}

	void test_gethostbyname_localhost_fqdn() {
		sockaddr_in output;
		int gai_errno;
		std::string fqdn;
		cut_assert_equal_int(0, util::gethostbyname("localhost", 12121, AF_INET, output, gai_errno, &fqdn));
		cut_assert_equal_int(0, gai_errno);
		cut_assert_equal_int(AF_INET, output.sin_family);
		cut_assert_equal_int(12121, ntohs(output.sin_port));
		in_addr reference;
		inet_aton("127.0.0.1", &reference);
		cut_assert_equal_memory(&reference.s_addr, sizeof(reference), &output.sin_addr.s_addr, sizeof(reference));
		cut_assert_equal_int(0, fqdn.find("localhost", 0));
	}

	const char plain[] = "All your base are belong to us";

	void test_base64_encode()
	{
		string expected = "QWxsIHlvdXIgYmFzZSBhcmUgYmVsb25nIHRvIHVz";
		string result = util::base64_encode(plain, strlen(plain));
		
		cut_assert_equal_string(expected.c_str(), result.c_str());
	}

	void test_base64_decode()
	{
		string expected = "All your base are belong to us";
		size_t siz;
		
		string encoded = "QWxsIHlvdXIgYmFzZSBhcmUgYmVsb25nIHRvIHVz";
		char *p = util::base64_decode(encoded, siz);
		string result(p, siz);
		cut_assert_equal_string(expected.c_str(), result.c_str());
		delete[] p;
	}

	void test_next_word_buffer_overflow()
	{
		char buffer[2];
		util::next_word("abc", buffer, sizeof(buffer));
		cut_assert_equal_uint(1, strlen(buffer));
		cut_assert_equal_string("a", buffer);
	}

	void test_next_word_bad_space_handling()
	{
		char buffer[2];
		util::next_word("   a", buffer, sizeof(buffer));
		cut_assert_equal_uint(1, strlen(buffer));
		cut_assert_equal_string("a", buffer);
	}

	void test_next_digit_buffer_overflow()
	{
		char buffer[2];
		util::next_word("123", buffer, sizeof(buffer));
		cut_assert_equal_uint(1, strlen(buffer));
		cut_assert_equal_string("1", buffer);
	}

	void test_next_digit_bad_space_handling()
	{
		char buffer[2];
		util::next_word("   1", buffer, sizeof(buffer));
		cut_assert_equal_uint(1, strlen(buffer));
		cut_assert_equal_string("1", buffer);
	}

	void test_realtime_zero()
	{
		cut_assert_equal_int(0, util::realtime(0));
	}

	void test_realtime_relative()
	{
		cut_assert_equal_double(stats_object->get_timestamp() + 30, 2, util::realtime(30));
	}

	void test_realtime_limit()
	{
		const int limit = 60*60*24*30;
		cut_assert_equal_double(stats_object->get_timestamp() + limit, 2, util::realtime(limit));
		cut_assert_equal_int(limit + 1, util::realtime(limit + 1));
	}

	void test_realtime_absolute()
	{
		cut_assert_equal_int(1353317300, util::realtime(1353317300)); // 1353317300 = 2012/11/19 18:30 JST
	}

	const int atomic_count_num=1024*1024;
	void* atomic_count_incr(void* ptr){
		AtomicCounter* cnt=(AtomicCounter*)ptr;
		for(int i=0;i<atomic_count_num;i++){
			cnt->incr();
		}
		return NULL;
	}

	void* atomic_count_decr(void* ptr){
		AtomicCounter* cnt=(AtomicCounter*)ptr;
		for(int i=0;i<atomic_count_num;i++){
			cnt->add(-1);
		}
		return NULL;
	}

	void test_atomic_counter()
	{
		{
			AtomicCounter cnt(100);
			cut_assert_equal_int(cnt.fetch(),100);
			cut_assert_equal_int(cnt.add(100),100);
			cut_assert_equal_int(cnt.fetch(),200);
			cut_assert_equal_int(cnt.incr(),200);
			cut_assert_equal_int(cnt.incr(),201);
			cut_assert_equal_int(cnt.incr(),202);
			cut_assert_equal_int(cnt.incr(),203);
			cut_assert_equal_int(cnt.fetch(),204);
		}
		{
			AtomicCounter cnt(0);
			cut_assert_equal_int(cnt.fetch(),0);
			cut_assert_equal_int(cnt.incr(),0);
			cut_assert_equal_int(cnt.incr(),1);
			cut_assert_equal_int(cnt.incr(),2);
			cut_assert_equal_int(cnt.incr(),3);
			cut_assert_equal_int(cnt.add(-1),4);
			cut_assert_equal_int(cnt.add(-1),3);
			cut_assert_equal_int(cnt.add(-1),2);
			cut_assert_equal_int(cnt.fetch(),1);
		}
		{
			const int initval=-1024;
			AtomicCounter cnt(initval);
			const int tnum=128;
			const int retval =tnum*atomic_count_num+initval;
			pthread_t threads[tnum];
			for(int i=0;i<tnum;i++){
				pthread_create(threads+i,NULL,atomic_count_incr,(void*)&cnt);
			}
			for(int i=0;i<tnum;i++){
				pthread_join(threads[i],NULL);
			}
			cut_assert_equal_int(cnt.fetch(),retval);
			for(int i=0;i<tnum;i++){
				pthread_create(threads+i,NULL,atomic_count_decr,(void*)&cnt);
			}
			for(int i=0;i<tnum;i++){
				pthread_join(threads[i],NULL);
			}
			cut_assert_equal_int(cnt.fetch(),initval);
		}
	}
}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
