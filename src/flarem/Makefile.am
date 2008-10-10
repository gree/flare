#
#   Makefile.am
#
#   $Id$
#

# forward compatibility
datarootdir = @datarootdir@

# main
bin_PROGRAMS = flarem
DEFS = -Wall $(FLARE_CXXFLAGS)
LDADD = ../lib/libflare.a

# src
flarem_CPPFLAGS = -I../lib
flarem_SOURCES = \
	flarem.h flarem.cc \
	ini_option.h ini_option.cc \
	handler_request.h handler_request.cc \
	op_parser_binary_manager.h op_parser_binary_manager.cc \
	op_parser_text_manager.h op_parser_text_manager.cc \
	op_stats_manager.h op_stats_manager.cc \
	stats_manager.h stats_manager.cc
