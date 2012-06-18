/**
 *	test-util.cc
 *
 *	@author	Kiyoshi Ikehara <kiyoshi.ikehara@gree.net>
 */

#include <cppcutter.h>
#include <pthread.h>

#include <errno.h>
#include <util.h>

#if defined(__APPLE__) && defined(__MACH__)
#define YIELD pthread_yield_np();
#else
#define YIELD pthread_yield();
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
	}

	void teardown()
	{
		strerror_expected.clear();
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
			cppcut_assert_equal(strerror_expected[errnos[j]], error);
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
			cppcut_assert_equal(before, after);
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
		cppcut_assert_equal(static_cast<in_addr_t>(htonl(0x00000000)),
												util::inet_addr("12.34.56.78", htonl(0x00000000)));
		cppcut_assert_equal(static_cast<in_addr_t>(htonl(0x0c22384e)),
												util::inet_addr("12.34.56.78", htonl(0xffffffff)));
		cppcut_assert_equal(static_cast<in_addr_t>(htonl(0x0c223000)),
												util::inet_addr("12.34.56.78", htonl(0xfffff000)));
		for (int sh = 1; sh <= 32; sh++) {
			cppcut_assert_equal(static_cast<in_addr_t>(htonl(0x0c22384e & (0xffffffff << sh))),
													util::inet_addr("12.34.56.78", htonl(0xffffffff << sh)));
		}
	}

	const char plain[] = "All your base are belong to us";

	void test_base64_encode()
	{
		string expected = "QWxsIHlvdXIgYmFzZSBhcmUgYmVsb25nIHRvIHVz";
		string result = util::base64_encode(plain, strlen(plain));
		
		cppcut_assert_equal(expected, result);
	}

	void test_base64_decode()
	{
		string expected = "All your base are belong to us";
		size_t siz;
		
		string encoded = "QWxsIHlvdXIgYmFzZSBhcmUgYmVsb25nIHRvIHVz";
		char *p = util::base64_decode(encoded, siz);
		string result(p, siz);
		cppcut_assert_equal(expected, result);
		delete[] p;
	}

}
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
