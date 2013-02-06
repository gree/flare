/**
 *	test_op.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 */

#define EXPOSE(op, function) \
		using gree::flare::op::function;

#define TEST_OP_CLASS_BEGIN(op, ...) \
	struct test_##op : public gree::flare::op \
	{ \
		test_##op(gree::flare::shared_connection c) : op(c, ##__VA_ARGS__) { } \
		EXPOSE(op, _parse_text_server_parameters) \
		EXPOSE(op, _run_server) \
		EXPOSE(op, _run_client) \
		EXPOSE(op, _parse_text_client_parameters) \
		EXPOSE(op, _parse_binary_client_parameters) \
		EXPOSE(op, _parse_text_response) \
		EXPOSE(op, _result) \
		EXPOSE(op, _result_message)

#define TEST_OP_CLASS_END \
	};

// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
