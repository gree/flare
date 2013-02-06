#!/bin/sh

export BASE_DIR="$( cd "$( dirname "$0" )" && pwd )"
TOP_DIR="$BASE_DIR/.."

if test x"$NO_MAKE" != x"yes"; then
    make -C $TOP_DIR > /dev/null || exit 1
fi

if test -z "$CUTTER"; then
    CUTTER="`make -s -C $BASE_DIR echo-cutter`"
fi
export CUTTER

if test -z "$VALGRIND"; then
    VALGRIND="`make -s -C $BASE_DIR echo-valgrind`"
fi
export VALGRIND

if test -n "$CUTTER"; then
	LOG_DIR=$BASE_DIR/log
	if [ ! -d $LOG_DIR ]; then
		mkdir $LOG_DIR
	fi
	LOG_FILE=$LOG_DIR/cutter_report.xml
	CUTTER_ARGS="--keep-opening-modules --xml-report=$LOG_FILE -v v"
	CUTTER_WRAPPER=""
	if test x"$CUTTER_DEBUG" = x"yes"; then
	    CUTTER_WRAPPER="$TOP_DIR/libtool --mode=execute gdb --args"
	elif test x"$CUTTER_CHECK_LEAKS" = x"yes"; then
	    VALGRIND_ARGS="--leak-check=full --show-reachable=yes -v"
	    CUTTER_WRAPPER="$TOP_DIR/libtool --mode=execute $VALGRIND $VALGRIND_ARGS"
	fi
	CUTTER_ARGS="$CUTTER_ARGS -s $BASE_DIR"

	$CUTTER_WRAPPER $CUTTER $CUTTER_ARGS "$@" $BASE_DIR
else
	echo "cutter executable not found."
fi
