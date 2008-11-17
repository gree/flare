#
#   Makefile.am
#
#   $Id$
#

# forward compatibility
datarootdir = @datarootdir@

noinst_LIBRARIES = libflare.a

DEFS = -Wall $(FLARE_CXXFLAGS)

libflare_a_SOURCES = \
	app.h app.cc \
	cluster.h cluster.cc \
	connection.h connection.cc \
	handler_monitor.h handler_monitor.cc \
	handler_proxy.h handler_proxy.cc \
	handler_reconstruction.h handler_reconstruction.cc \
	ini.h ini.cc \
	logger.h logger.cc \
	mm.h mm.cc \
	net.h net.cc \
	op.cc op.h \
	op_add.h op_add.cc \
	op_cas.h op_cas.cc \
	op_decr.h op_decr.cc \
	op_delete.h op_delete.cc \
	op_dump.h op_dump.cc \
	op_error.h op_error.cc \
	op_flush_all.h op_flush_all.cc \
	op_get.h op_get.cc \
	op_gets.h op_gets.cc \
	op_incr.h op_incr.cc \
	op_kill.h op_kill.cc \
	op_node_add.h op_node_add.cc \
	op_node_remove.h op_node_remove.cc \
	op_node_role.h op_node_role.cc \
	op_node_state.h op_node_state.cc \
	op_node_sync.h op_node_sync.cc \
	op_parser.h op_parser.cc\
	op_parser_binary.h op_parser_binary.cc \
	op_parser_text.h op_parser_text.cc \
	op_ping.h op_ping.cc \
	op_proxy_read.h op_proxy_read.cc \
	op_proxy_write.h op_proxy_write.cc \
	op_quit.h op_quit.cc \
	op_replace.h op_replace.cc \
	op_set.h op_set.cc \
	op_stats.h op_stats.cc \
	op_verbosity.h op_verbosity.cc \
	op_version.h op_version.cc \
	queue_node_sync.h queue_node_sync.cc \
	queue_proxy_read.h queue_proxy_read.cc \
	queue_proxy_write.h queue_proxy_write.cc \
	queue_update_monitor_option.h queue_update_monitor_option.cc \
	server.h server.cc \
	singleton.h \
	stats.h stats.cc \
	storage.h storage.cc \
	storage_tch.h storage_tch.cc \
	util.h util.cc \
	thread.h thread.cc \
	thread_handler.h \
	thread_pool.h thread_pool.cc \
	thread_queue.h thread_queue.cc
