#!/bin/sh
#
# Init file for Barnyard2
#
#
# chkconfig: 2345 40 60
# description:  Barnyard2 is an output processor for snort.
#
# processname: barnyard2
# config: /etc/sysconfig/barnyard2
# config: /etc/snort/barnyard.conf
# pidfile: /var/lock/subsys/barnyard2.pid


[ -x /usr/sbin/snort ] || exit 1
[ -r /etc/snort/snort.conf ] || exit 1

### Default variables
SYSCONFIG="/etc/default/barnyard2"

### Read configuration
[ -r "$SYSCONFIG" ] && . "$SYSCONFIG"

RETVAL=0
prog="barnyard2"
desc="Snort Output Processor"

start() {
       echo -n $"Starting $desc ($prog): "
       for INT in $INTERFACES; do
               PIDFILE="/var/lock/barnyard2-$INT.pid"
               ARCHIVEDIR="$SNORTDIR/archive"
               WALDO_FILE="$SNORTDIR/barnyard2.waldo"
               BARNYARD_OPTS="-D -c $CONF -d $SNORTDIR -w $WALDO_FILE -l $SNORTDIR -a $ARCHIVEDIR -f $LOG_FILE -X $PIDFILE $EXTRA_ARGS"
               $prog $BARNYARD_OPTS
       done
       RETVAL=$?
       echo
       [ $RETVAL -eq 0 ] && touch /var/lock/$prog
       return $RETVAL
}

stop() {
       echo -n $"Shutting down $desc ($prog): "
       killall $prog
       RETVAL=$?
       echo
       [ $RETVAL -eq 0 ] && rm -f /var/lock/$prog
       return $RETVAL
}

restart() {
       stop
       start
}


reload() {
       echo -n $"Reloading $desc ($prog): "
       killall $prog -HUP
       RETVAL=$?
       echo
       return $RETVAL
}


case "$1" in
 start)
       start
       ;;
 stop)
       stop
       ;;
 restart)
       restart
       ;;
 reload)
       reload
       ;;
 condrestart)
       [ -e /var/lock/$prog ] && restart
       RETVAL=$?
       ;;
 status)
       status $prog
       RETVAL=$?
       ;;
dump)
       dump
       ;;
 *)
       echo $"Usage: $0 {start|stop|restart|reload|condrestart|status|dump}"
       RETVAL=1
esac

exit $RETVAL
