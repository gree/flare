if WITH_CUTTER
noinst_LTLIBRARIES =	\
	test_binary_header.la \
	test_cluster.la \
	test_connection_tcp.la \
	test_connection_iostream.la \
	test_handler_proxy.la \
	test_storage.la \
	test_storage_entry.la \
	test_storage_tcb.la \
	test_storage_tch.la \
	test_key_resolver_modular.la \
	test_op.la	\
	test_op_add.la	\
	test_op_append.la	\
	test_op_cas.la	\
	test_op_decr.la	\
	test_op_delete.la	\
	test_op_dump.la	\
	test_op_dump_key.la	\
	test_op_error.la	\
	test_op_flush_all.la	\
	test_op_gat.la	\
	test_op_get.la	\
	test_op_gets.la	\
	test_op_incr.la	\
	test_op_keys.la	\
	test_op_kill.la	\
	test_op_meta.la	\
	test_op_node_add.la	\
	test_op_node_remove.la	\
	test_op_node_role.la	\
	test_op_node_state.la	\
	test_op_node_sync.la	\
	test_op_parser.la	\
	test_op_ping.la	\
	test_op_prepend.la	\
	test_op_quit.la	\
	test_op_replace.la	\
	test_op_set.la	\
	test_op_show.la	\
	test_op_shutdown.la	\
	test_op_stats.la	\
	test_op_touch.la	\
	test_op_verbosity.la	\
	test_op_version.la	\
	test_thread_pool.la	\
	test_util.la	\
	test_file_coordinator.la
if ENABLE_KYOTOCABINET
noinst_LTLIBRARIES += test_storage_kch.la
endif
if ENABLE_ZOOKEEPER
noinst_LTLIBRARIES += test_zookeeper_coordinator.la test_zookeeper_lock.la
endif
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

test_binary_header_la_SOURCES	= test_binary_header.cc connection_iostream.cc
test_connection_tcp_la_SOURCES	= test_connection_tcp.cc common_connection_tests.cc
test_cluster_la_SOURCES	= test_cluster.cc
test_connection_iostream_la_SOURCES	= test_connection_iostream.cc common_connection_tests.cc connection_iostream.cc
test_handler_proxy_la_SOURCES	= test_handler_proxy.cc mock_cluster.h
test_storage_la_SOURCES	= test_storage.cc
test_storage_entry_la_SOURCES	= test_storage_entry.cc
test_storage_tcb_la_SOURCES	= test_storage_tcb.cc common_storage_tests.cc
test_storage_tch_la_SOURCES	= test_storage_tch.cc common_storage_tests.cc
if ENABLE_KYOTOCABINET
test_storage_kch_la_SOURCES	= test_storage_kch.cc common_storage_tests.cc
endif
test_key_resolver_modular_la_SOURCES	= test_key_resolver_modular.cc
test_op_la_SOURCES	= test_op.cc connection_iostream.cc
test_op_add_la_SOURCES	= test_op_add.cc connection_iostream.cc
test_op_append_la_SOURCES	= test_op_append.cc connection_iostream.cc
test_op_cas_la_SOURCES	= test_op_cas.cc connection_iostream.cc
test_op_decr_la_SOURCES	= test_op_decr.cc connection_iostream.cc
test_op_delete_la_SOURCES	= test_op_delete.cc connection_iostream.cc
test_op_dump_la_SOURCES	= test_op_dump.cc connection_iostream.cc
test_op_dump_key_la_SOURCES	= test_op_dump_key.cc connection_iostream.cc
test_op_error_la_SOURCES	= test_op_error.cc connection_iostream.cc
test_op_flush_all_la_SOURCES	= test_op_flush_all.cc connection_iostream.cc
test_op_gat_la_SOURCES	= test_op_gat.cc connection_iostream.cc
test_op_get_la_SOURCES	= test_op_get.cc connection_iostream.cc
test_op_gets_la_SOURCES	= test_op_gets.cc connection_iostream.cc
test_op_incr_la_SOURCES	= test_op_incr.cc connection_iostream.cc
test_op_keys_la_SOURCES	= test_op_keys.cc connection_iostream.cc
test_op_kill_la_SOURCES	= test_op_kill.cc connection_iostream.cc
test_op_meta_la_SOURCES	= test_op_meta.cc connection_iostream.cc
test_op_node_add_la_SOURCES	= test_op_node_add.cc connection_iostream.cc
test_op_node_remove_la_SOURCES	= test_op_node_remove.cc connection_iostream.cc
test_op_node_role_la_SOURCES	= test_op_node_role.cc connection_iostream.cc
test_op_node_state_la_SOURCES	= test_op_node_state.cc connection_iostream.cc
test_op_node_sync_la_SOURCES	= test_op_node_sync.cc connection_iostream.cc
test_op_parser_la_SOURCES	= test_op_parser.cc connection_iostream.cc
test_op_ping_la_SOURCES	= test_op_ping.cc connection_iostream.cc
test_op_prepend_la_SOURCES	= test_op_prepend.cc connection_iostream.cc
test_op_quit_la_SOURCES	= test_op_quit.cc connection_iostream.cc
test_op_replace_la_SOURCES	= test_op_replace.cc connection_iostream.cc
test_op_set_la_SOURCES	= test_op_set.cc connection_iostream.cc
test_op_show_la_SOURCES	= test_op_show.cc connection_iostream.cc
test_op_shutdown_la_SOURCES	= test_op_shutdown.cc connection_iostream.cc
test_op_stats_la_SOURCES	= test_op_stats.cc connection_iostream.cc
test_op_touch_la_SOURCES	= test_op_touch.cc connection_iostream.cc
test_op_verbosity_la_SOURCES	= test_op_verbosity.cc connection_iostream.cc
test_op_version_la_SOURCES	= test_op_version.cc connection_iostream.cc
test_thread_pool_la_SOURCES	= test_thread_pool.cc
test_util_la_SOURCES	= test_util.cc
test_file_coordinator_la_SOURCES	= test_file_coordinator.cc
if ENABLE_ZOOKEEPER
test_zookeeper_coordinator_la_SOURCES	= test_zookeeper_coordinator.cc
test_zookeeper_lock_la_SOURCES		= test_zookeeper_lock.cc
endif
