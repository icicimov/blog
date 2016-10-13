#!/bin/bash
#
# barnyard2		Start up the barnyard2 Intrusion Detection System daemon
#
# chkconfig: 2345 98 25
# description: barnyard2 is a Open Source Intrusion Detection System
#              This service starts up the barnyard2 daemon.
#
# processname: barnyard2
# pidfile: /var/run/barnyard2_eth0.pid

### BEGIN INIT INFO
# Provides: barnyard2
# Required-Start: $local_fs $network $syslog
# Required-Stop: $local_fs $syslog
# Should-Start: $syslog
# Should-Stop: $network $syslog
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: Start up the barnyard2 snort parser
# Description:       barnyard2 is a parser for snort binary files (unified2 format).
#		     This service starts up the barnyard2 IDS daemon.
### END INIT INFO

# source function library
. /etc/rc.d/init.d/functions

# pull in sysconfig settings
[ -f /etc/sysconfig/barnyard2 ] && . /etc/sysconfig/barnyard2

RETVAL=0
prog="barnyard2"
lockfile=/var/lock/subsys/$prog

# Some functions to make the below more readable
BARNYARD=/usr/local/bin/barnyard2
#OPTIONS="-D -u snort -g snort -c /etc/snort/barnyard2.conf -l /var/log/snort -a /var/log/snort/archive -f snort.u2"
#PID_FILE=/var/run/barnyard2.pid

# Convert the /etc/sysconfig/barnyard2 settings to something barnyard2 can
# use on the startup line.
if [ "$USER"X = "X" ]; then
   USER="snort"
fi

if [ "$GROUP"X = "X" ]; then
   GROUP="snort"
fi

if [ "$CONF"X = "X" ]; then
   CONF="-c /etc/snort/barnyard2.conf"
else
   CONF="-c $CONF"
fi

if [ "$INTERFACE"X = "X" ]; then
   HW_INTF="eth0"
   INTERFACE="-i eth0"
   PID_FILE="/var/run/barnyard2_eth0.pid"
else
   HW_INTF=$INTERFACE
   PID_FILE="/var/run/barnyard2_$INTERFACE.pid"
   INTERFACE="-i $INTERFACE"
fi

if [ "$SNORTDIR"X = "X" ]; then
   SNORTDIR=/var/log/snort
fi

if [ "$LOG_FILE"X = "X" ]; then
   LOG_FILE="snort.u2"
fi

if [ "$ARCHIVEDIR"X = "X" ]; then
   SNORTDIR="$SNORTDIR/archive"
fi

if [ "$WALDO_FILE"X = "X" ]; then
   LOG_FILE="$SNORTDIR/barnyard2.waldo"
fi

BARNYARD_OPTS="-D $CONF -d $SNORTDIR -w $WALDO_FILE -l $SNORTDIR -a $ARCHIVEDIR -f $LOG_FILE $EXTRA_ARGS"

runlevel=$(set -- $(runlevel); eval "echo \$$#" )

start()
{
	[ -x $BARNYARD ] || exit 5

	echo -n $"Starting $prog: "
	daemon --pidfile=$PID_FILE $BARNYARD $BARNYARD_OPTS && success || failure
	#$BARNYARD $BARNYARD_OPTS && success || failure
	RETVAL=$?
	[ $RETVAL -eq 0 ] && touch $lockfile
	echo
	return $RETVAL
}

stop()
{
	echo -n $"Stopping $prog: "
	killproc $BARNYARD
	if [ -e $PID_FILE ]; then
	    RUN_FILE=/var/run/barnyard2_$HW_INTF
	    chown $USER:$GROUP $RUN_FILE.* &&
	    rm -f $PID_FILE
	    rm -f $PID_FILE.lck
	    rm -f $lockfile
	fi
	RETVAL=$?
	# if we are in halt or reboot runlevel kill all running sessions
	# so the TCP connections are closed cleanly
	if [ "x$runlevel" = x0 -o "x$runlevel" = x6 ] ; then
	    trap '' TERM
	    killall $prog 2>/dev/null
	    trap TERM
	fi
	[ $RETVAL -eq 0 ] && rm -f $lockfile
	echo
	return $RETVAL
}

restart() {
	stop
	start
}

rh_status() {
	status -p $PID_FILE $BARNYARD 
}

rh_status_q() {
	rh_status >/dev/null 2>&1
}

case "$1" in
	start)
		rh_status_q && exit 0
		start
		;;
	stop)
		if ! rh_status_q; then
			rm -f $lockfile
			exit 0
		fi
		stop
		;;
	restart)
		restart
		;;
	status)
		rh_status
		RETVAL=$?
		if [ $RETVAL -eq 3 -a -f $lockfile ] ; then
			RETVAL=2
		fi
		;;
	*)
		echo $"Usage: $0 {start|stop|restart|status}"
		RETVAL=2
esac
exit $RETVAL
