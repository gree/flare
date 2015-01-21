if WITH_CUTTER
noinst_LTLIBRARIES =	\
	test_lib.la
endif

AM_CXXFLAGS =				\
	-I$(top_srcdir)			\
	-I$(top_srcdir)/src/lib	\
	$(FLARE_CXXFLAGS)		\
	$(CPPCUTTER_CFLAGS)

AM_LDFLAGS =			\
	-module				\
	-rpath $(libdir)	\
	-avoid-version		\
	$(FLARE_LDFLAGS)

LIBS =									\
	$(top_builddir)/src/lib/libflare.la	\
	$(CPPCUTTER_LIBS)

test_lib_la_SOURCES = \
	test_binary_header.cc \
	test_connection_tcp.cc \
	test_cluster.cc \
	test_cluster_replication.cc \
	test_connection_iostream.cc \
	test_handler_proxy.cc \
	test_handler_cluster_replication.cc \
	test_handler_dump_replication.cc \
	test_server_app.cc \
	test_storage.cc \
	test_storage_entry.cc \
	test_storage_tcb.cc \
	test_storage_tch.cc \
	test_key_resolver_modular.cc \
	test_op.cc \
	test_op_add.cc \
	test_op_append.cc \
	test_op_cas.cc \
	test_op_decr.cc \
	test_op_delete.cc \
	test_op_dump.cc \
	test_op_dump_key.cc \
	test_op_error.cc \
	test_op_flush_all.cc \
	test_op_gat.cc \
	test_op_get.cc \
	test_op_gets.cc \
	test_op_incr.cc \
	test_op_keys.cc \
	test_op_kill.cc \
	test_op_meta.cc \
	test_op_node_add.cc \
	test_op_node_remove.cc \
	test_op_node_role.cc \
	test_op_node_state.cc \
	test_op_node_sync.cc \
	test_op_parser.cc \
	test_op_ping.cc \
	test_op_prepend.cc \
	test_op_quit.cc \
	test_op_replace.cc \
	test_op_set.cc \
	test_op_show.cc \
	test_op_shutdown.cc \
	test_op_stats.cc \
	test_op_touch.cc \
	test_op_verbosity.cc \
	test_op_version.cc \
	test_queue_forward_query.cc \
	test_thread_pool.cc \
	test_time_util.cc \
	test_time_watcher.cc \
	test_util.cc \
	test_file_coordinator.cc
if ENABLE_ZOOKEEPER
test_lib_la_SOURCES += \
	test_zookeeper_coordinator.cc \
	test_zookeeper_lock.cc
endif
test_lib_la_SOURCES += \
	connection_iostream.cc \
	common_connection_tests.cc \
	common_storage_tests.cc \
	mock_storage.cc \
	mock_cluster.cc
