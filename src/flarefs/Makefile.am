#
#   Makefile.am
#
#   $Id$
#

# forward compatibility
datarootdir = @datarootdir@

# main
if ENABLE_FLAREFS
bin_PROGRAMS = flarefs
else
bin_PROGRAMS =
endif

DEFS = -Wall $(FLARE_CXXFLAGS)
LDADD = ../lib/libflare.la

# src
flarefs_CPPFLAGS = -I../lib -D_FILE_OFFSET_BITS=64
flarefs_SOURCES = \
	flarefs.h flarefs.cc \
	fuse_fs.h fuse_fs.cc \
	fuse_fs_entry.h fuse_fs_entry.cc \
	fuse_fs_entry_dir.h fuse_fs_entry_dir.cc \
	fuse_fs_entry_file.h fuse_fs_entry_file.cc \
	fuse_impl.h fuse_impl.cc \
	ini_option.h ini_option.cc
