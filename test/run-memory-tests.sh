#!/bin/sh

PLATFORM="$(uname)"
if test "$PLATFORM" != "Linux"; then
	echo "Memory checks are only available on Linux (detected platform: $PLATFORM)"
	exit 77
fi

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

TMP_FILE=$(mktemp /tmp/flare.tests.XXXXXX)
trap "rm -f $TMP_FILE" EXIT

if test -n "$CUTTER" -a -n "$VALGRIND"; then
	CUTTER_ARGS="--disable-signal-handling --keep-opening-modules -v n -s $BASE_DIR"
	VALGRIND_ARGS="--leak-check=full --log-file=$TMP_FILE"
	CUTTER_WRAPPER="$TOP_DIR/libtool --mode=execute $VALGRIND $VALGRIND_ARGS"

	CMD_LINE="$CUTTER_WRAPPER $CUTTER $CUTTER_ARGS "$@" $BASE_DIR"
	echo "Running valgrind memory checks..."
	$CMD_LINE
	LEAKED_MEM=$(grep "definitely lost:" $TMP_FILE | sed "s/.* \([0-9,]*\) bytes .*/\1/" | sed s/,//g)
	echo "valgrind has reported $LEAKED_MEM bytes definitely lost."
	LOG_DIR=$BASE_DIR/log
	if [ ! -d $LOG_DIR ]; then
		mkdir $LOG_DIR
	fi
	LOG_FILE=$LOG_DIR/flare_memcheck.log
	cp $TMP_FILE $LOG_FILE
	echo "Log file saved in $LOG_FILE."
	if test $LEAKED_MEM -eq 0; then
		exit 0
	else
		exit 1
	fi
else
	echo "cutter or valgrind executable not found."
fi
