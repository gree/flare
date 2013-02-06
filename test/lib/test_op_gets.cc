/**
 *	test_op_gets.cc
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#include <cppcutter.h>

#include "test_op.h"
#include "connection_iostream.h"

#include <app.h>
#include <op_gets.h>

using namespace gree::flare;

namespace test_op_gets
{
	TEST_OP_CLASS_BEGIN(op_gets, NULL, NULL)
	TEST_OP_CLASS_END;

	void setup()
	{
		stats_object = new stats();
		stats_object->update_timestamp();
	}

	// Parameter parsing is common with op_get. Please refer to test_op_get.cc

	void teardown()
	{
		delete stats_object;
	}
}

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
