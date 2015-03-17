#
#   Makefile.am
#
#   $Id$
#

# forward compatibility
datarootdir = @datarootdir@

noinst_LTLIBRARIES = libflare.la

DEFS = -Wall $(FLARE_CXXFLAGS)

libflare_la_SOURCES = \
	app.h app.cc \
	binary_header.h \
	binary_network_mapping.h \
	binary_request_header.h \
	binary_response_header.h \
	bwlimitter.cc \
	client.h client.cc \
	cluster.h cluster.cc \
	cluster_replication.h cluster_replication.cc \
	cluster_replication_listener.h \
	connection.h \
	connection_tcp.h connection_tcp.cc \
	handler_cluster_replication.h handler_cluster_replication.cc \
	handler_controller.h handler_controller.cc \
	handler_dump_replication.h handler_dump_replication.cc \
	handler_monitor.h handler_monitor.cc \
	handler_proxy.h handler_proxy.cc \
	handler_reconstruction.h handler_reconstruction.cc \
	htonll.h \
	key_resolver.h key_resolver.cc \
	key_resolver_modular.h key_resolver_modular.cc \
	ini.h ini.cc \
	logger.h logger.cc \
	mysql_replication.h mysql_replication.cc \
	op.cc op.h \
	op_add.h op_add.cc \
	op_append.h op_append.cc \
	op_cas.h op_cas.cc \
	op_decr.h op_decr.cc \
	op_delete.h op_delete.cc \
	op_dump.h op_dump.cc \
	op_dump_key.h op_dump_key.cc \
	op_error.h op_error.cc \
	op_flush_all.h op_flush_all.cc \
	op_gat.h op_gat.cc \
	op_get.h op_get.cc \
	op_getk.h op_getk.cc \
	op_gets.h op_gets.cc \
	op_incr.h op_incr.cc \
	op_keys.h op_keys.cc \
	op_kill.h op_kill.cc \
	op_meta.h op_meta.cc \
	op_node_add.h op_node_add.cc \
	op_node_remove.h op_node_remove.cc \
	op_node_role.h op_node_role.cc \
	op_node_state.h op_node_state.cc \
	op_node_sync.h op_node_sync.cc \
	op_parser.h op_parser.cc\
	op_parser_binary.h op_parser_binary.cc \
	op_parser_text.h op_parser_text.cc \
	op_ping.h op_ping.cc \
	op_prepend.h op_prepend.cc \
	op_proxy_read.h op_proxy_read.cc \
	op_proxy_write.h op_proxy_write.cc \
	op_quit.h op_quit.cc \
	op_replace.h op_replace.cc \
	op_set.h op_set.cc \
	op_stats.h op_stats.cc \
	op_touch.h op_touch.cc \
	op_verbosity.h op_verbosity.cc \
	op_version.h op_version.cc \
	op_show.h op_show.cc \
	op_shutdown.h op_shutdown.cc \
	queue_node_state.h queue_node_state.cc \
	queue_node_sync.h queue_node_sync.cc \
	queue_proxy_read.h queue_proxy_read.cc \
	queue_proxy_write.h queue_proxy_write.cc \
	queue_update_monitor_option.h queue_update_monitor_option.cc \
	server.h server.cc \
	singleton.h \
	stats.h stats.cc \
	status.h \
	storage.h storage.cc \
	storage_tcb.h storage_tcb.cc \
	storage_tch.h storage_tch.cc \
	storage_listener.h \
	util.h util.cc \
	thread.h thread.cc \
	thread_handler.h \
	thread_pool.h thread_pool.cc \
	thread_queue.h thread_queue.cc \
	time_util.h time_util.cc \
	time_watcher.h time_watcher.cc \
	time_watcher_observer.h time_watcher_observer.cc \
	time_watcher_processor.h time_watcher_processor.cc \
	time_watcher_scoped_observer.h time_watcher_scoped_observer.cc \
	time_watcher_target_info.h \
	coordinator.h coordinator.cc \
	coordinator_factory.h coordinator_factory.cc \
	file_coordinator.h file_coordinator.cc \
	proxy_event_listener.h
if ENABLE_ZOOKEEPER
libflare_la_SOURCES += zookeeper_lock.h zookeeper_lock.cc zookeeper_coordinator.h zookeeper_coordinator.cc
endif
if ENABLE_KYOTOCABINET
libflare_la_SOURCES += storage_kch.h storage_kch.cc
endif
