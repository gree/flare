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
	ini.h ini.cc \
	logger.h logger.cc \
	mm.h mm.cc \
	net.h net.cc \
	op.cc op.h \
	op_error.h op_error.cc \
	op_kill.h op_kill.cc \
	op_node_add.h op_node_add.cc \
	op_node_sync.h op_node_sync.cc \
	op_parser.h op_parser.cc\
	op_parser_binary.h op_parser_binary.cc \
	op_parser_text.h op_parser_text.cc \
	op_ping.h op_ping.cc \
	op_quit.h op_quit.cc \
	op_stats.h op_stats.cc \
	op_version.h op_version.cc \
	queue_node_sync.h queue_node_sync.cc \
	queue_update_monitor_interval.h queue_update_monitor_interval.cc \
	server.h server.cc \
	stats.h stats.cc \
	util.h util.cc \
	thread.h thread.cc \
	thread_handler.h \
	thread_pool.h thread_pool.cc \
	thread_queue.h thread_queue.cc \
	singleton.h
