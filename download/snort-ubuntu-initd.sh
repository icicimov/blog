#!/bin/sh
# $Id$
#
# snort         Start/Stop the snort IDS daemon.
#
# chkconfig: 2345 40 60
# description:  snort is a lightweight network intrusion detection tool that \
#                currently detects more than 1100 host and network \
#                vulnerabilities, portscans, backdoors, and more.
#

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Source the local configuration file
. /etc/default/snort

# Convert the /etc/sysconfig/snort settings to something snort can
# use on the startup line.
if [ "$ALERTMODE"X = "X" ]; then
  ALERTMODE=""
else
  ALERTMODE="-A $ALERTMODE"
fi

if [ "$USER"X = "X" ]; then
  USER="snort"
fi

if [ "$GROUP"X = "X" ]; then
  GROUP="snort"
fi

if [ "$BINARY_LOG"X = "1X" ]; then
  BINARY_LOG="-b"
else
  BINARY_LOG=""
fi

if [ "$CONF"X = "X" ]; then
  CONF="-c /etc/snort/snort.conf"
else
  CONF="-c $CONF"
fi

if [ "$INTERFACE"X = "X" ]; then
  INTERFACE="eth0"
fi

if [ "$DUMP_APP"X = "1X" ]; then
  DUMP_APP="-d"
else
  DUMP_APP=""
fi 

if [ "$NO_PACKET_LOG"X = "1X" ]; then
  NO_PACKET_LOG="-N"
else
  NO_PACKET_LOG=""
fi        

if [ "$PRINT_INTERFACE"X = "1X" ]; then
  PRINT_INTERFACE="-I"
else
  PRINT_INTERFACE=""
fi

if [ "$PASS_FIRST"X = "1X" ]; then
  PASS_FIRST="-o"
else
  PASS_FIRST=""
fi

if [ "$LOGDIR"X = "X" ]; then
  LOGDIR=/var/log/snort
fi

# These are used by the 'stats' option
if [ "$SYSLOG"X = "X" ]; then
  SYSLOG=/var/log/messages
fi

if [ "$SECS"X = "X" ]; then
  SECS=5
fi

if [ ! "$BPFFILE"X = "X" ]; then
  BPFFILE="-F $BPFFILE"
fi


case "$1" in
 start)
       echo -n "Starting snort: "
       mkdir -p $LOGDIR
       chown -R $USER $LOGDIR
       /usr/sbin/snort $ALERTMODE $BINARY_LOG $NO_PACKET_LOG $DUMP_APP -e -v $PRINT_INTERFACE -i $INTERFACE -u $USER -g $GROUP $CONF -l $LOGDIR $PASS_FIRST $BPFFILE $BPF -D
       touch /var/lock/snort
       echo
       ;;
 stop)
       echo -n "Stopping snort: "
       killall snort
       rm -f /var/lock/snort
       echo 
       ;;
 reload)
       echo "Sorry, not implemented yet"
       ;;
 restart)
       $0 stop
       $0 start
       ;;
 condrestart)
       [ -e /var/lock/snort ] && $0 restart
       ;;
 status)
       status snort
       ;;
 *)
       echo "Usage: $0 {start|stop|reload|restart|condrestart|status}"
       exit 2
esac

exit 0
