#
#   Makefile.am
#
#   $Id$
#

# forward compatibility
datarootdir = @datarootdir@

# main
bin_PROGRAMS = flarei
DEFS = -Wall $(FLARE_CXXFLAGS)
LDADD = ../lib/libflare.la

# src
flarei_CPPFLAGS = -I../lib
flarei_SOURCES = \
	flarei.h flarei.cc \
	ini_option.h ini_option.cc \
	handler_alarm.h handler_alarm.cc \
	handler_request.h handler_request.cc \
	op_parser_binary_index.h op_parser_binary_index.cc \
	op_parser_text_index.h op_parser_text_index.cc \
	op_stats_index.h op_stats_index.cc \
	op_show_index.h op_show_index.cc \
	stats_index.h stats_index.cc \
	status_index.h status_index.cc
