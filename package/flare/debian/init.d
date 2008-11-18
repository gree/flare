#! /bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
RUN_INDEX=yes
RUN_NODE=yes
DAEMON_INDEX=/usr/bin/flarei
DAEMON_NODE=/usr/bin/flared
DESC=flare
DESC_INDEX=`basename $DAEMON_INDEX`
DESC_NODE=`basename $DAEMON_NODE`
NAME=flare
NAME_INDEX=$DESC_INDEX
NAME_NODE=$DESC_NODE
CONF_INDEX=/etc/flarei.conf
CONF_NODE=/etc/flared.conf
DATA_INDEX=/tmp
DATA_NODE=/tmp

test -x $DAEMON_INDEX || exit 0
test -x $DAEMON_NODE || exit 0

# Include flare defaults if available
if [ -f /etc/default/flare ] ; then
	. /etc/default/flare
fi

set -e

case "$1" in
  start)
	echo -n "Starting $DESC: "
	if [ $RUN_INDEX = "yes" ]; then
		start-stop-daemon --start --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX -- -f $CONF_INDEX --daemonize
		echo -n "$NAME_INDEX "
	fi
	sleep 1
	if [ $RUN_NODE = "yes" ]; then
		start-stop-daemon --start --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE -- -f $CONF_NODE --daemonize
		echo -n "$NAME_NODE "
	fi
	echo ""
  	;;
  start-index)
	echo -n "Starting $DESC_INDEX: "
	if [ $RUN_INDEX = "yes" ]; then
		start-stop-daemon --start --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX -- -f $CONF_INDEX --daemonize
		echo "$NAME_INDEX."
	else
		echo "disabled (skip starting)."
	fi
	;;
  start-node)
	echo -n "Starting $DESC_NODE: "
	if [ $RUN_NODE = "yes" ]; then
		start-stop-daemon --start --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE -- -f $CONF_NODE --daemonize
		echo "$NAME_NODE."
	else
		echo "disabled (skip starting)."
	fi
	;;
  stop)
	echo -n "Stopping $DESC: "
	if [ $RUN_INDEX = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX
		echo -n "$NAME_INDEX "
	fi
	sleep 1
	if [ $RUN_NODE = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE
		echo -n "$NAME_NODE "
	fi
	echo ""
  	;;
  stop-index)
	echo -n "Stopping $DESC_INDEX: "
	if [ $RUN_INDEX = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX
		echo "$NAME_INDEX."
	else
		echo "disabled (skip stopping)."
	fi
	;;
  stop-node)
	echo -n "Stopping $DESC_NODE: "
	if [ $RUN_NODE = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE
		echo "$NAME_NODE."
	else
		echo "disabled (skip stopping)."
	fi
	;;
  reload)
	if [ $RUN_INDEX = "yes" ]; then
		echo "Reloading $DESC_INDEX configuration files."
		start-stop-daemon --stop --signal 1 --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON
	fi
	if [ $RUN_NODE = "yes" ]; then
		echo "Reloading $DESC_NODE configuration files."
		start-stop-daemon --stop --signal 1 --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON
	fi
  	;;
  reload-index)
	if [ $RUN_INDEX = "yes" ]; then
		echo "Reloading $DESC_INDEX configuration files."
		start-stop-daemon --stop --signal 1 --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON
	fi
	;;
  reload-node)
	if [ $RUN_NODE = "yes" ]; then
		echo "Reloading $DESC_NODE configuration files."
		start-stop-daemon --stop --signal 1 --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON
	fi
	;;
  restart)
    echo -n "Restarting $DESC: "
	if [ $RUN_INDEX = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX
		sleep 1
		start-stop-daemon --start --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX -- -f $CONF_INDEX --daemonize
		echo -n "$NAME_INDEX "
	fi
	sleep 1
	if [ $RUN_NODE = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE
		sleep 1
		start-stop-daemon --start --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE -- -f $CONF_NODE --daemonize
		echo -n "$NAME_NODE "
	fi
	echo ""
	;;
  restart-index)
    echo -n "Restarting $DESC_INDEX: "
	if [ $RUN_INDEX = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX
		sleep 1
		start-stop-daemon --start --quiet --pidfile $DATA_INDEX/$NAME_INDEX.pid --exec $DAEMON_INDEX -- -f $CONF_INDEX --daemonize
		echo "$NAME_INDEX."
	else
		echo "disable (skip restarting)."
	fi
	;;
  restart-node)
    echo -n "Restarting $DESC_NODE: "
	if [ $RUN_NODE = "yes" ]; then
		start-stop-daemon --stop --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE
		sleep 1
		start-stop-daemon --start --quiet --pidfile $DATA_NODE/$NAME_NODE.pid --exec $DAEMON_NODE -- -f $CONF_NODE --daemonize
		echo "$NAME_NODE."
	else
		echo "disable (skip restarting)."
	fi
	;;
  *)
	N=/etc/init.d/$NAME
	echo "Usage: $N {start|start-index|start-node|stop|stop-index|stop-node|restart|restart-index|restart-node|reload|reload-index|reload-node}" >&2
	exit 1
	;;
esac

exit 0
