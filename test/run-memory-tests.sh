#!/bin/sh

PLATFORM="$(uname)"
if [ "$PLATFORM" != "Linux" ]; then
	echo "Memory checks are only available on Linux (detected platform: $PLATFORM)"
	exit 77
fi

export BASE_DIR="$( cd "$( dirname "$0" )" && pwd )"
TOP_DIR="$BASE_DIR/.."

if [ x"$NO_MAKE" != x"yes" ]; then
    make -C $TOP_DIR > /dev/null || exit 1
fi

if [ -z "$CUTTER" ]; then
    CUTTER=$(make -s -C $BASE_DIR echo-cutter)
fi
export CUTTER

if [ -z "$VALGRIND" ]; then
    VALGRIND=$(make -s -C $BASE_DIR echo-valgrind)
fi
export VALGRIND

VALGRIND_VERSION=$($VALGRIND --version | cut -d '-' -f 2)
VALGRIND_MAJOR=$(echo $VALGRIND_VERSION | sed "s/^\([0-9]\)\..*/\1/")
VALGRIND_MINOR=$(echo $VALGRIND_VERSION | sed "s/^[0-9]*\.\([0-9]*\)\..*/\1/")
if [ $VALGRIND_MAJOR -lt 3 -o \( $VALGRIND_MAJOR -eq 3 -a $VALGRIND_MINOR -lt 8 \) ]; then
    echo "Flare memory tests require valgrind version 3.8 at least (detected version: $VALGRIND_VERSION)"
    exit 77
fi

TMP_FILE=$(mktemp /tmp/flare.tests.XXXXXX)
trap "rm -f $TMP_FILE" EXIT

if [ -n "$CUTTER" -a -n "$VALGRIND" ]; then
	CUTTER_ARGS="--disable-signal-handling --keep-opening-modules -v n -s $BASE_DIR"
	VALGRIND_ARGS="--leak-check=full --log-file=$TMP_FILE --suppressions=$BASE_DIR/flare.supp --gen-suppressions=all"
	CUTTER_WRAPPER="$TOP_DIR/libtool --mode=execute $VALGRIND $VALGRIND_ARGS"

	CMD_LINE="$CUTTER_WRAPPER $CUTTER $CUTTER_ARGS "$@" $BASE_DIR"
	echo "Running valgrind memory checks..."
	$CMD_LINE
	LEAKED_MEM=$(grep -m 1 "definitely lost:" $TMP_FILE | sed "s/.* \([0-9,]*\) bytes .*/\1/" | sed s/,//g)
	echo "valgrind has reported $LEAKED_MEM bytes definitely lost."
	LOG_DIR=$BASE_DIR/log
	if [ ! -d $LOG_DIR ]; then
		mkdir $LOG_DIR
	fi
	LOG_FILE=$LOG_DIR/flare_memcheck.log
	cp $TMP_FILE $LOG_FILE
	echo "Log file saved in $LOG_FILE."
	if [ $LEAKED_MEM -eq 0 ]; then
		exit 0
	else
		exit 1
	fi
else
	echo "cutter or valgrind executable not found."
fi
