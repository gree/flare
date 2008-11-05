#
#   Makefile.am
#
#   $Id$
#

# forward compatibility
datarootdir = @datarootdir@

# main
bin_PROGRAMS = flared
DEFS = -Wall $(FLARE_CXXFLAGS)
LDADD = ../lib/libflare.a

# src
flared_CPPFLAGS = -I../lib
flared_SOURCES = \
	flared.h flared.cc \
	ini_option.h ini_option.cc \
	handler_alarm.h handler_alarm.cc \
	handler_request.h handler_request.cc \
	op_parser_binary_node.h op_parser_binary_node.cc \
	op_parser_text_node.h op_parser_text_node.cc \
	op_stats_node.h op_stats_node.cc \
	stats_node.h stats_node.cc
