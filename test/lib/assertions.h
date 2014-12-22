/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
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