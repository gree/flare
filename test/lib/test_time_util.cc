#include <cppcutter.h>
#include "time_util.h"

using namespace std;
using namespace gree::flare;

namespace test_time_util {
	void setup() {
	}

	void teardown() {
	}

	void test_msec_to_timespec () {
		timespec actual;
		actual = time_util::msec_to_timespec(1500);
		cut_assert_equal_int(1, actual.tv_sec);
		cut_assert_equal_int(500000000, actual.tv_nsec);

		actual = time_util::msec_to_timespec(340);
		cut_assert_equal_int(0, actual.tv_sec);
		cut_assert_equal_int(340000000, actual.tv_nsec);
	}

void test_timeval_to_timespec () {
	timeval val;
	timespec actual;

	val.tv_sec = 1;
	val.tv_usec = 12345;
	actual = time_util::timeval_to_timespec(val);
	cut_assert_equal_int(1, actual.tv_sec);
	cut_assert_equal_int(12345000, actual.tv_nsec);
}

	void test_timer_sub () {
		timespec actual;
		timespec a;
		timespec b;

		a.tv_sec = 15;
		a.tv_nsec = 25;
		b.tv_sec = 10;
		b.tv_nsec = 20;
		actual = time_util::sub(a, b);
		cut_assert_equal_int(5, actual.tv_sec);
		cut_assert_equal_int(5, actual.tv_nsec);

		a.tv_sec = 15;
		a.tv_nsec = 25;
		b.tv_sec = 0;
		b.tv_nsec = 40;
		actual = time_util::sub(a, b);
		cut_assert_equal_int(14, actual.tv_sec);
		cut_assert_equal_int(999999985, actual.tv_nsec);

		a.tv_sec = 15;
		a.tv_nsec = 25;
		b.tv_sec = 30;
		b.tv_nsec = 25;
		actual = time_util::sub(a, b);
		cut_assert_equal_int(-15, actual.tv_sec);
		cut_assert_equal_int(0, actual.tv_nsec);
	}

	void test_timer_is_bigger () {
		timespec a;
		timespec b;

		// bigger
		a.tv_sec = 15;
		a.tv_nsec = 25;
		b.tv_sec = 10;
		b.tv_nsec = 20;
		cut_assert_true(time_util::is_bigger(a, b));

		a.tv_sec = 15;
		a.tv_nsec = 25;
		b.tv_sec = 15;
		b.tv_nsec = 20;
		cut_assert_true(time_util::is_bigger(a, b));

		// same
		a.tv_sec = 15;
		a.tv_nsec = 25;
		b.tv_sec = 15;
		b.tv_nsec = 25;
		cut_assert_false(time_util::is_bigger(a, b));

		// smaller
		a.tv_sec = 15;
		a.tv_nsec = 25;
		b.tv_sec = 15;
		b.tv_nsec = 35;
		cut_assert_false(time_util::is_bigger(a, b));
	}
}
