#ifndef	ASSERTIONS_H
#define	ASSERTIONS_H

#include <config.h>
#include <inttypes.h>
#include <cppcutter.h>

void flare_assert_nearly_equal_int64(int64_t expected, int64_t actual, int64_t epsilon) {
	cut_assert(
		static_cast<int64_t>(llabs(expected - actual)) < epsilon,
		cut_message("expected:%" PRId64 " is not less than actual:%" PRId64 " allowable error max:%"
		PRId64, expected, actual, epsilon)
	);
}

void flare_assert_less_than_int64(int64_t expected, int64_t actual) {
	cut_assert(expected < actual, cut_message("expected:%" PRId64 "is not less than actual:%" PRId64, expected, actual));
}

#endif