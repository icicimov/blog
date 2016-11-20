---
type: posts
header:
  teaser: '4940499208_b79b77fb0a_z.jpg'
title: 'Managing system resources with Cgroups and Ansible'
categories: 
  - DevOps
tags: [cgroups, ansible, automation]
related: true
---

Sometimes we need to limit particular resource usage for some process, utility or group of processes in order to prioritize or limit their usage. One way to achieve this in the modern Linux kernel is via `Cgroups`. They provide kernel feature that limits, accounts for and isolates the resource usage (CPU, memory, disk I/O, network, etc.) of a collection of processes.

## Implementation

The following example shows using cgroups to limit the CPU usage and number of CPU cores for specific utility, in this case the html-to-pdf conversion tool `wkhtmltopdf`. First we install the needed packages:

$ sudo aptitude install cgroup-bin cgmanager-utils

On Ubuntu/Debian the cgroups file system mounts under `/sys/fs/cgroups` where all available sub systems get created. To find the capabilities and available cgroup subsystems:

```
$ cat /proc/cgroups
#subsys_name    hierarchy    num_cgroups    enabled
cpuset    3    2    1
cpu    4    2    1
cpuacct    5    1    1
memory    6    1    1
devices    7    1    1
freezer    8    1    1
blkio    9    1    1
perf_event    10    1    1
hugetlb    11    1    1
```

Now we can set the cgroup and set it's limits:

```
$ sudo cgcreate -g cpu,cpuset:/group1
$ sudo cgset -r cpuset.cpus='0,2,4,6' group1
$ sudo cgset -r cpu.shares='512' group1
```

This will create the group1 under cpu and cpuset subsystems of cgroups. We can check the set values:

```
$ cat /sys/fs/cgroup/cpuset/group1/cpuset.cpus
0,2,4,6
 
$ cat /sys/fs/cgroup/cpu/group1/cpu.shares
512
```

The above created cgroup limits its tasks to only run on cpu cores 0,2,4 and 6 and use max of 50% cpu cycles on those cores. The cpu capacity is represented with shares and each core has 1024 shares in total, which means setting the shares to 512 sets around 50% of the cpu cycles for the tasks. The most important part though is that limitations are not going to be applied UNTIL there is other processes running on the same cores competing for 100% of the cpu usage. Meaning the tasks have in total 100% of cpu available on each core and they can use it all if needed. Also the cpu utilization of 50% is a relative value and doesn't mean that the tasks are given exactly 50% of cpu on each of the 4 cores but rather an overall utilization for the allocated resources. In case of contention they might get 20% on core 2 but 10% on cores 0,4 and 6 for example which will give it a total of 50%.

Now, if we want to limit a process in terms of cpu utilization we can add it to the `group1` we created. We have several options for this:

* We can add already running process to the group. Example:

  ```
  # cgclassify -g cpu,cpuset:/group1 $PID
  ```

* We can start a process or execute command utility bound to the group. Examples:

  ```
  # cgexec -g cpu,cpuset:/group1 /usr/local/bin/wkhtmltopdf file.html
  # cgexec -g cpu,cpuset:/group1 httpd
  ```

* We can adjust the default startup parameters of a process so it automatically starts in the group. Example in `/etc/sysconfig/httpd` or `/etc/default/apache2`:

  ```
  ...
  CGROUP_DAEMON="cpu,cpuset:/group1"
  ```

* We can use cgrep daemon `cgrepd` which assigns tasks to particular groups based on the settings of the `/etc/cgrules.conf` file on run-time. Example:
    
  ```
  # echo 'tomcat7:wkhtmltopdf    cpu,cpuset    group1' >  /etc/cgrules.conf
      
  # cgrulesengd -d -v -f /var/log/cgrulesengd.log &
     
  # cat /var/log/cgrulesengd.log
  CGroup Rules Engine Daemon log started
  Current time: Thu Jan 15 16:04:20 2015
     
  Opened log file: /var/log/cgrulesengd.log, log facility: 0, log level: 7
  Proceeding with PID 28569
  Rule: tomcat7:wkhtmltopdf
    UID: 500
    GID: N/A
    DEST: group1
    CONTROLLERS:
      cpu
      cpuset
     
  Started the CGroup Rules Engine Daemon.
  ```

Now to automate all this on start-up I've created systemv init script for the `cgred` daemon for Ubuntu by modifying the one provided in the package for RedHat `/etc/init.d/cgred`:

```bash
#!/bin/bash
#
# Start/Stop the CGroups Rules Engine Daemon
#
# Copyright Red Hat Inc. 2008
#
# Authors:    Steve Olivieri <sjo@redhat.com>
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2.1 of the GNU Lesser General Public License
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it would be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# cgred        CGroups Rules Engine Daemon
# chkconfig:    - 14 86
# description:    This is a daemon for automatically classifying processes \
#        into cgroups based on UID/GID.
#
# processname: cgrulesengd
# pidfile: /var/run/cgred.pid
#
### BEGIN INIT INFO
# Provides:        cgrulesengd
# Required-Start:    $local_fs $syslog
# Required-Stop:    $local_fs $syslog
# Default-Start:        2 3 4 5
# Default-Stop:         0 1 6
# Short-Description:    start and stop the cgroups rules engine daemon
# Description:        CGroup Rules Engine is a tool for automatically using \
#            cgroups to classify processes
### END INIT INFO
 
prefix=/usr;exec_prefix=${prefix};sbindir=${exec_prefix}/sbin
CGRED_BIN=$sbindir/cgrulesengd
CGRED_CONF=/etc/cgrules.conf
 
# Sanity checks
[ -x $CGRED_BIN ] || exit 1
 
# Source function library & LSB routines
#. /etc/init.d/functions
. /lib/init/vars.sh
. /lib/lsb/init-functions
 
# Read in configuration options.
if [ -f "/etc/default/cgred" ] ; then
    . /etc/default/cgred
    OPTIONS="$NODAEMON $LOG"
    if [ -n "$LOG_FILE" ]; then
        OPTIONS="$OPTIONS --logfile=$LOG_FILE"
    fi
    if [ -n "$SOCKET_USER" ]; then
        OPTIONS="$OPTIONS -u $SOCKET_USER"
    fi
    if [ -n "$SOCKET_GROUP" ]; then
        OPTIONS="$OPTIONS -g $SOCKET_GROUP"
    fi
else
    OPTIONS=""
fi
 
# For convenience
processname=cgrulesengd
servicename=cgred
lockfile="/var/lock/$servicename"
pidfile=/var/run/cgred.pid
 
start()
{
    echo -n $"Starting CGroup Rules Engine Daemon: "
    if [ -f "$lockfile" ]; then
        log_failure_msg "$servicename is already running with PID `cat ${pidfile}`"
        return 0
    fi
    if [ ! -s $CGRED_CONF ]; then
        log_failure_msg "not configured"
        return 6
    fi
    if ! grep "^cgroup" /proc/mounts &>/dev/null; then
        echo
        log_failure_msg $"Cannot find cgroups, is cgconfig service running?"
        return 1
    fi
    start-stop-daemon --start -b --pidfile "$pidfile" -x $CGRED_BIN -- $OPTIONS
    retval=$?
    if [ $retval -ne 0 ]; then
        return 7
    fi
    touch "$lockfile"
    if [ $? -ne 0 ]; then
        return 1
    fi
    sleep 2
    echo "`pidof $processname`" > $pidfile
    return 0
}
 
stop()
{
    echo -n $"Stopping CGroup Rules Engine Daemon..."
    if [ ! -f $pidfile ]; then
        log_success_msg
        return 0
    fi
    #killproc -p $pidfile -TERM "$processname"
    start-stop-daemon --stop --pidfile "$pidfile" --retry=TERM/20/KILL/5
    #killall -TERM $processname
    retval=$?
    echo
    if [ $retval -ne 0 ]; then
        return 1
    fi
    rm -f "$lockfile" "$pidfile"
    return 0
}
 
status () {
    status_of_proc -p $pidfile $servicename "$processname"
}
 
RETVAL=0
 
# See how we are called
case "$1" in
    start)
        start
        RETVAL=$?
        ;;
    stop)
        stop
        RETVAL=$?
        ;;
    status)
        status && exit 0 || exit $?
        ;;
    restart)
        stop
        start
        RETVAL=$?
        ;;
    *)
        echo $"Usage: $0 {start|stop|restart}"
        RETVAL=2
        ;;
esac
 
exit $RETVAL
```

make it executable and set it for autostart on proper runlevels:

```
$ sudo chmod +x /etc/init.d/cgred
$ sudo update-rc.d defaults 99 20
```

Then we can grab thedefault cgred config that comes with the documentation:

```
$ sudo cp /usr/share/doc/cgroup-bin/examples/cgred.conf /etc/default/cgred
```

and modify it slightly `/etc/default/cgred`:

```
CONFIG_FILE="/etc/cgrules.conf"
LOG_FILE="/var/log/cgrulesengd.log"
NODAEMON=""
#NODAEMON="--nodaemon"
SOCKET_USER=""
#SOCKET_GROUP="cgred"
SOCKET_GROUP=""
#LOG=""
#LOG="--nolog"
LOG="-v"
```

Then we can use the standard service command to start/stop the daemon:

```
$ sudo service cgred [start|stop|status|restart]
```

We also need to parse the rules file and dynamically create our cgroup on start-up. We create the following file for this purpose `/etc/cgconfig.conf`:

```
group group1 {
    cpuset {
        cpuset.memory_spread_slab="0";
        cpuset.memory_spread_page="0";
        cpuset.memory_migrate="0";
        cpuset.sched_relax_domain_level="-1";
        cpuset.sched_load_balance="1";
        cpuset.mem_hardwall="0";
        cpuset.mem_exclusive="0";
        cpuset.cpu_exclusive="0";
        cpuset.mems="0";
        cpuset.cpus="0,2,4,6";
    }
}
group group1 {
    cpu {
        cpu.cfs_period_us="100000";
        cpu.cfs_quota_us="-1";
        cpu.shares="512";
    }
}
```

and run the parsing command on start-up which we add to rc.local file `/etc/rc.local`:

```
...
cgconfigparser -l /etc/cgconfig.conf
 
exit 0
```

That's it, now our cgroup, with cpu and cpuset subsystems attached to it, will get automatically created on start-up and the cgred daemon started to automatically move the wkhtmltopdf processes to the cgroup, but only if there are other processes competing for 100% CPU usage on the same core that the wkhtmltopdf process is also running on.

## Automating with Ansible

Now we want this done on each server we have the tool running. The following playbook will do the same as above but in dynamic fashion, finding out the number of CPU's on the server and adjusting the numbers for the cpu cores and cpu shares in the `/etc/cgconfig.conf` represented by an `Ansible` template. 

```bash
---
#
# Cgroups setup
#
- ec2_facts:

- set_fact:
   cpu_cores: |
    {% raw %}{%- for core in range((ansible_processor_vcpus/2)|round(0,'ceil')|int) -%}
      {{ core }}{% if not loop.last %},{% endif %}
    {%- endfor -%}{% endraw %}

- name: Update apt
  apt: update_cache=yes
  when: ansible_os_family == "Debian"
  register: result
  until: result|success
  retries: 10

- name: install cgroups
  apt: pkg={{ item }} state=present
  with_items: [ 'cgroup-lite', 'cgroup-bin', 'numactl' ]

- copy: src=cgsnapshot_blacklist.conf dest=/etc/cgsnapshot_blacklist.conf owner=root group=root mode=0644

- name: configure our cpu cgroup
  template: src=cgconfig.conf.j2 dest=/etc/cgconfig.conf owner=root group=root mode=0644

- name: cgrules config file
  copy: src=cgrules.conf dest=/etc/cgrules.conf owner=root group=root mode=0644

- name: create the cgroup
  command: cgconfigparser -l /etc/cgconfig.conf

- name: set cgconfigparser for autostart
  lineinfile:
    dest=/etc/rc.local
    line="cgconfigparser -l /etc/cgconfig.conf"
    insertbefore='exit 0'

- name: setup the cgred daemon
  copy: src=cgred.init dest=/etc/init.d/cgred owner=root group=root mode=0755

- name: set the cgred defaults config
  copy: src=cgred.conf dest=/etc/default/cgred owner=root group=root mode=0644
  notify: restart cgred

- name: autostart cgred
  command: update-rc.d cgred defaults 99 15
```

the template `cgconfig.conf.j2` looks like:

```
group group1 {
    cpuset {
        cpuset.memory_spread_slab="0";
        cpuset.memory_spread_page="0";
        cpuset.memory_migrate="0";
        cpuset.sched_relax_domain_level="-1";
        cpuset.sched_load_balance="1";
        cpuset.mem_hardwall="0";
        cpuset.mem_exclusive="0";
        cpuset.cpu_exclusive="0";
        cpuset.mems="0";
        cpuset.cpus="{% raw %}{{ cpu_cores }}{% endraw %}";
    }
}

group group1 {
    cpu {
        cpu.cfs_period_us="100000";
        cpu.cfs_quota_us="-1";
        cpu.shares="{% raw %}{{ cpu_shares }}{% endraw %}";
    }
}
```

The rest of the files are static. We organize all this nicely into a role that we call each time a new server is launched in EC2.