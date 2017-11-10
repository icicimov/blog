---
type: posts
header:
  teaser: 'cluster.jpg'
title: 'PostgreSQL High Availibility with Pacemaker'
categories: 
  - Database
tags: [high-availability, cluster, postgresql]
date: 2017-2-9
series: "OpenATTIC 2-node cluster setup"
---

Setting up PostgreSQL synchronous or asynchronous replication cluster with Pacemaker is described in couple of resources like the official Pacemaker site [PgSQL Replicated Cluster](http://wiki.clusterlabs.org/wiki/PgSQL_Replicated_Cluster) and the GitHub wiki of the OCF agent creator [Resource Agent for PostgreSQL 9.1 streaming replication](https://github.com/t-matsuo/resource-agents/wiki/Resource-Agent-for-PostgreSQL-9.1-streaming-replication). My setup is displayed in the ASCII chart below:


```
                        GW:192.168.0.1/24
                               |
  VIP(Master):192.168.0.241/24 | VIP(Slave):192.168.0.242/24
  ------------------------------------------------
         |                              |
         |eth0:192.168.0.134/24         |eth0:192.168.0.135/24
   ------------                   ------------ 
   | oattic01 |                   | oattic02 |
   ------------                   ------------
      |   |eth1:10.10.1.16/24        |     |eth1:10.10.1.17/24
   ---|---x--------------------------|-----x------
   ---x------------------------------x------------
      eth2:10.20.1.10/24             eth2:10.20.1.18/24
             VIP(Replication):10.20.1.200/24
```

The `10.10.1.0/24` network will be used for `Corosync` communication ie the primary `ring0` channel. The `10.20.1.0/24` network will be used for the PostgreSQL replication link and as a secondary standby `ring1` for Corosync in case of ring0 failure. The `192.168.0.0/24` is the network where the PostgreSQL clustered service will be available to the clients. This network is also used to provide Internet access to the boxes. The `Master VIP` will be the IP on which the PGSQL service will be provided in the cluster. The `Slave VIP` is a read-only IP that will always be associated with the Slave so the applications can use it for read operations only (this is really optional so can be dropped from the setup if not needed). The `Replication VIP` is the IP on which the PGSQL replication will be running over separate link from the service one to avoid any mutual interference.

PostgreSQL version installed is 9.3.5 in this case.

{% include series.html %}

# Streaming Replication Setup

Create our PostgreSQL streaming replication configuration file `/etc/postgresql/9.3/main/custom.conf` on `oattic01` which we want to be our initial Master:

```
# REPLICATION AND ARCHIVING #
listen_addresses = '*'
log_line_prefix = '%t [%p] %u@%d '
wal_level = hot_standby
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/9.3/main/pg_archive/%f && cp %p /var/lib/postgresql/9.3/main/pg_archive/%f'
max_wal_senders = 5
wal_keep_segments = 32
checkpoint_segments = 16
hot_standby = on
hot_standby_feedback = on
wal_sender_timeout = 5000
wal_receiver_status_interval = 2
max_standby_streaming_delay = -1
max_standby_archive_delay = -1
synchronous_commit = on
restart_after_crash = off
```

and add it at the bottom of PGSQL configuration file `/etc/postgresql/9.3/main/postgresql.conf`:

```
include_if_exists = 'custom.conf'	# include file only if it exists
```

Then create a replication user:

```
root@oattic01:~$ sudo -u postgres psql -c "CREATE ROLE replication WITH REPLICATION PASSWORD 'password' LOGIN;"
```

and restart the service:

```
user@oattic02:~$ sudo service postgresql restart
```

Then we move to `oattic02`, stop the service and perform initial sync with the `oattic01` database:

```
user@oattic02:~$ sudo service postgresql stop

user@oattic02:~$ sudo -u postgres rm -rf /var/lib/postgresql/9.3/main/

user@oattic02:~$ sudo -u postgres pg_basebackup -h 10.20.1.10 -D /var/lib/postgresql/9.3/main -U replication -v -P
57253/57253 kB (100%), 1/1 tablespace                                         
NOTICE:  pg_stop_backup complete, all required WAL segments have been archived
pg_basebackup: base backup completed
```

Then create the same streaming replication file `/etc/postgresql/9.3/main/custom.conf` on `oattic02`.

To test the replication we create a recovery file `/var/lib/postgresql/9.3/main/recovery.conf` with the following content:

``` 
standby_mode = 'on'
primary_conninfo = 'host=10.20.1.10 port=5432 user=postgres application_name=oattic02'
restore_command = 'cp /var/lib/postgresql/9.3/main/pg_archive/%f %p'
recovery_target_timeline='latest'
```

and restart the service:

```
user@oattic02:~$ sudo service postgresql start
 * Starting PostgreSQL 9.3 database server           [OK ] 
```

while monitoring the db log file in same time:

```
user@oattic02:~$ tail -f /var/log/postgresql/postgresql-9.3-main.log
2017-02-08 16:50:19 AEDT [6019] [unknown]@[unknown] LOG:  incomplete startup packet
2017-02-08 16:50:20 AEDT [6022] postgres@postgres FATAL:  the database system is starting up
cp: cannot stat ‘/var/lib/postgresql/9.3/main/pg_archive/00000002.history’: No such file or directory
2017-02-08 16:50:20 AEDT [6018] @ LOG:  entering standby mode
cp: cannot stat ‘/var/lib/postgresql/9.3/main/pg_archive/000000010000000000000002’: No such file or directory
2017-02-08 16:50:20 AEDT [6027] @ LOG:  started streaming WAL from primary at 0/2000000 on timeline 1
2017-02-08 16:50:20 AEDT [6030] postgres@postgres FATAL:  the database system is starting up
2017-02-08 16:50:20 AEDT [6018] @ LOG:  redo starts at 0/2000028
2017-02-08 16:50:20 AEDT [6018] @ LOG:  consistent recovery state reached at 0/20000F0
2017-02-08 16:50:20 AEDT [6017] @ LOG:  database system is ready to accept read only connections
```

To confirm all has gone well we check the `xlog` location on the Master:

```
postgres@oattic01:~$ psql
psql (9.3.15)
Type "help" for help.
 
postgres=# \l
                                    List of databases
      Name      |  Owner   | Encoding |   Collate   |    Ctype    |   Access privileges   
----------------+----------+----------+-------------+-------------+-----------------------
 postgres       | postgres | UTF8     | en_AU.UTF-8 | en_AU.UTF-8 | 
 template0      | postgres | UTF8     | en_AU.UTF-8 | en_AU.UTF-8 | =c/postgres          +
                |          |          |             |             | postgres=CTc/postgres
 template1      | postgres | UTF8     | en_AU.UTF-8 | en_AU.UTF-8 | =c/postgres          +
                |          |          |             |             | postgres=CTc/postgres
(3 rows)

postgres=# SELECT pg_current_xlog_location();
 pg_current_xlog_location 
--------------------------
 0/3000208
(1 row)

postgres=# 
```

and the xlog replay location on the current slave oattic02:

```
root@oattic02:~# su - postgres
postgres@oattic02:~$ psql
psql (9.3.15)
Type "help" for help.

postgres=# \l
                                    List of databases
      Name      |  Owner   | Encoding |   Collate   |    Ctype    |   Access privileges   
----------------+----------+----------+-------------+-------------+-----------------------
 postgres       | postgres | UTF8     | en_AU.UTF-8 | en_AU.UTF-8 | 
 template0      | postgres | UTF8     | en_AU.UTF-8 | en_AU.UTF-8 | =c/postgres          +
                |          |          |             |             | postgres=CTc/postgres
 template1      | postgres | UTF8     | en_AU.UTF-8 | en_AU.UTF-8 | =c/postgres          +
                |          |          |             |             | postgres=CTc/postgres
(3 rows)

postgres=# select pg_last_xlog_replay_location();
 pg_last_xlog_replay_location 
------------------------------
 0/3000208
(1 row)

postgres=#
```

Now that we are confident the streaming replication is working we can move on to setting up the cluster.

# Cluster Setup

Install needed clustering packages on both nodes:

```
$ sudo aptitude install heartbeat pacemaker corosync fence-agents openais cluster-glue resource-agents
```

which will result in following:

```
root@oattic02:~# dpkg -l | grep -E "pacemaker|corosync|resource-agents"
ii  corosync                             2.3.3-1ubuntu3                       amd64        Standards-based cluster framework (daemon and modules)
ii  crmsh                                1.2.5+hg1034-1ubuntu4                all          CRM shell for the pacemaker cluster manager
ii  libcorosync-common4                  2.3.3-1ubuntu3                       amd64        Standards-based cluster framework, common library
ii  pacemaker                            1.1.10+git20130802-1ubuntu2.3        amd64        HA cluster resource manager
ii  pacemaker-cli-utils                  1.1.10+git20130802-1ubuntu2.3        amd64        Command line interface utilities for Pacemaker
ii  resource-agents                      1:3.9.3+git20121009-3ubuntu2         amd64        Cluster Resource Agents
```

Then create the Corosync config file `/etc/corosync/corosync.conf` on `oattic01`:

```
totem {
	version: 2

	# How long before declaring a token lost (ms)
	token: 3000

	# How many token retransmits before forming a new configuration
	token_retransmits_before_loss_const: 10

	# How long to wait for join messages in the membership protocol (ms)
	join: 60

	# How long to wait for consensus to be achieved before starting a new round of membership configuration (ms)
	consensus: 3600

	# Turn off the virtual synchrony filter
	vsftype: none

	# Number of messages that may be sent by one processor on receipt of the token
	max_messages: 20

	# Stagger sending the node join messages by 1..send_join ms
	send_join: 45

	# Limit generated nodeids to 31-bits (positive signed integers)
	clear_node_high_bit: yes

	# Disable encryption
 	secauth: off

	# How many threads to use for encryption/decryption
 	threads: 0

	# Optionally assign a fixed node id (integer)
	# nodeid: 1234

	# CLuster name, needed for DLM or DLM wouldn't start
	cluster_name: openattic

	# This specifies the mode of redundant ring, which may be none, active, or passive.
 	rrp_mode: passive

 	interface {
		ringnumber: 0
		bindnetaddr: 10.10.1.16
		mcastaddr: 226.94.1.1
		mcastport: 5405
	}
	interface {
		ringnumber: 1
		bindnetaddr: 10.20.1.10
		mcastaddr: 226.94.41.1
		mcastport: 5407
	}
	transport: udpu
}

nodelist {
	node {
		name: oattic01
		nodeid: 1
		quorum_votes: 1
		ring0_addr: 10.10.1.16
		ring1_addr: 10.20.1.10

	}
	node {
		name: oattic02
		nodeid: 2
		quorum_votes: 1
		ring0_addr: 10.10.1.17
		ring1_addr: 10.20.1.18
	}
}

quorum {
	provider: corosync_votequorum
	expected_votes: 2
	two_node: 1
	wait_for_all: 1
}

amf {
	mode: disabled
}

service {
 	# Load the Pacemaker Cluster Resource Manager
	# if 0: start pacemaker
	# if 1: don't start pacemaker
 	ver:       1
 	name:      pacemaker
}

aisexec {
        user:   root
        group:  root
}

logging {
        fileline: off
        to_stderr: yes
        to_logfile: no
        to_syslog: yes
        syslog_facility: daemon
        debug: off
        timestamp: on
        logger_subsys {
                subsys: QUORUM 
                debug: off
                tags: enter|leave|trace1|trace2|trace3|trace4|trace6
        }
}
```

The file on `oattic02` is basically same we just need to replace the values of the IP's for the `bindnetaddr` and the rings addresses with appropriate values for that node. After restarting the service on both nodes:

```
root@[ALL]:~# service corosync restart 
```

we can see both rings as functional:

```
root@oattic01:~# corosync-cfgtool -s
Printing ring status.
Local node ID 1
RING ID 0
	id	= 10.10.1.16
	status	= ring 0 active with no faults
RING ID 1
	id	= 10.20.1.10
	status	= ring 1 active with no faults

root@oattic02:~# corosync-cfgtool -s
Printing ring status.
Local node ID 2
RING ID 0
	id	= 10.10.1.17
	status	= ring 0 active with no faults
RING ID 1
	id	= 10.20.1.18
	status	= ring 1 active with no faults
```

and the quorum between the nodes established:

```
root@oattic01:~# corosync-quorumtool -l

Membership information
----------------------
    Nodeid      Votes Name
         1          1 10.10.1.16 (local)
         2          1 10.10.1.17
```

Add needed permission for remote access to postgresql for the `replication` and `openatticpgsql` users (this cluster will be used for OpenATTIC database in this case):

```
root@[ALL]:~# vi /etc/postgresql/9.3/main/pg_hba.conf
[...]
host    replication     all     		10.20.1.0/24	trust
host    openatticpgsql  openatticpgsql  10.20.1.0/24    md5
```

If not done already, ie the previous testing of replication was skipped, perform initial sync of the initial slave as described above:

```
user@oattic02:~$ sudo service postgresql stop
user@oattic02:~$ sudo -u postgres rm -rf /var/lib/postgresql/9.3/main/
user@oattic02:~$ sudo -u postgres pg_basebackup -h 10.20.1.10 -D /var/lib/postgresql/9.3/main -U replication -v -P
```

Stop postgresql on both nodes and replace `auto` with `disabled` in `/etc/postgresql/9.3/main/start.conf` since it will only be managed by Pacemaker and we want to prevent it from starting out of Pacemaker's control.

First download the OCF resource agent from [here](https://raw.githubusercontent.com/ClusterLabs/resource-agents/a6f4ddf76cb4bbc1b3df4c9b6632a6351b63c19e/heartbeat/pgsql), and
replace the default one which is buggy:

```
root@[ALL]:~# mv /usr/lib/ocf/resource.d/heartbeat/pgsql /usr/lib/ocf/resource.d/heartbeat/pgsql.default
root@[ALL]:~# wget -O /usr/lib/ocf/resource.d/heartbeat/pgsql https://raw.githubusercontent.com/ClusterLabs/resource-agents/a6f4ddf76cb4bbc1b3df4c9b6632a6351b63c19e/heartbeat/pgsql
root@[ALL]:~# chmod +x /usr/lib/ocf/resource.d/heartbeat/pgsql
```

Then on one of the servers create a `CIB` config file:

```
root@oattic01:~# vi cib.txt
property \
    no-quorum-policy="ignore" \
    stonith-enabled="false" \
    crmd-transition-delay="0s"
rsc_defaults \
    resource-stickiness="INFINITY" \
    migration-threshold="1"
primitive vip-master ocf:heartbeat:IPaddr2 \
    params ip="192.168.0.241" nic="eth0" cidr_netmask="24" \
    op start   timeout="60s" interval="0s"  on-fail="stop" \
    op monitor timeout="60s" interval="10s" on-fail="restart" \
    op stop    timeout="60s" interval="0s"  on-fail="block"
primitive vip-rep ocf:heartbeat:IPaddr2 \
    params ip="10.20.1.200" nic="eth2" cidr_netmask="24" \
    meta migration-threshold="0" \
    op start   timeout="60s" interval="0s"  on-fail="restart" \
    op monitor timeout="60s" interval="10s" on-fail="restart" \
    op stop    timeout="60s" interval="0s"  on-fail="block"
primitive vip-slave ocf:heartbeat:IPaddr2 \
    params ip="192.168.0.242" nic="eth0" cidr_netmask="24" \
    meta resource-stickiness="1" \
    op start   timeout="60s" interval="0s"  on-fail="restart" \
    op monitor timeout="60s" interval="10s" on-fail="restart" \
    op stop    timeout="60s" interval="0s"  on-fail="block"
primitive pgsql ocf:heartbeat:pgsql \
   params \
        pgctl="/usr/lib/postgresql/9.3/bin/pg_ctl" \
        psql="/usr/lib/postgresql/9.3/bin/psql" \
        pgdata="/var/lib/postgresql/9.3/main/" \
        start_opt="-p 5432" \
        config="/etc/postgresql/9.3/main/postgresql.conf" \
        logfile="/var/log/postgresql/postgresql-9.3-main.log" \
        rep_mode="sync" \
        node_list="oattic01 oattic02" \
        restore_command="test -f /var/lib/postgresql/9.3/main/pg_archive/%f && cp /var/lib/postgresql/9.3/main/pg_archive/%f %p" \
        primary_conninfo_opt="keepalives_idle=60 keepalives_interval=5 keepalives_count=5" \
        master_ip="10.20.1.200" \
        restart_on_promote="true" \
        stop_escalate="0" \
    op start   interval="0s" timeout="60s" on-fail="restart" \
    op monitor interval="4s" timeout="60s" on-fail="restart" \
    op monitor interval="3s" timeout="60s" on-fail="restart" role="Master" \
    op promote interval="0s" timeout="60s" on-fail="restart" \
    op demote  interval="0s" timeout="60s" on-fail="stop" \
    op stop    interval="0s" timeout="60s" on-fail="block" \
    op notify  interval="0s" timeout="60s"
ms msPostgresql pgsql \
    meta master-max="1" master-node-max="1" clone-max="2" clone-node-max="1" notify="true" interleave="true" target-role="Started"
primitive pingCheck ocf:pacemaker:ping \
    params name="default_ping_set" host_list="192.168.0.1" multiplier="100" \
    op start   timeout="60s" \
    op monitor timeout="60s" interval="10s" \
    op stop    timeout="60s" \
    op reload  timeout="100s"
clone clnPingCheck pingCheck
group master-group vip-master vip-rep \
      meta ordered="false"
location rsc_location-1 vip-slave \
    rule  200: pgsql-status eq "HS:sync" \
    rule  100: pgsql-status eq "PRI" \
    rule  -inf: not_defined pgsql-status \
    rule  -inf: pgsql-status ne "HS:sync" and pgsql-status ne "PRI"
location rsc_location-2 msPostgresql \
    rule -inf: not_defined default_ping_set or default_ping_set lt 100
colocation rsc_colocation-1 inf: msPostgresql  clnPingCheck
colocation rsc_colocation-2 inf: master-group  msPostgresql:Master
colocation rsc_colocation-3 inf: vip-slave     msPostgresql:Slave
order rsc_order-1 0: clnPingCheck          msPostgresql
order rsc_order-2 0: msPostgresql:promote  master-group:start   sequential=true symmetrical=false
order rsc_order-3 0: msPostgresql:demote   master-group:stop    sequential=true symmetrical=false
```

Make sure there aren't any left over recovery files from previous testing:

```
root@oattic02:~# rm -f /var/lib/postgresql/9.3/main/recovery.conf
```

Create the following dir on both servers needed by the OCF agent:

```
root@[ALL]:~# mkdir -p /var/lib/pgsql/tmp/
root@[ALL]:~# chown -R postgres\: /var/lib/pgsql
```

and then load the new configuration:

```
root@oattic01:~# crm configure load update cib.txt
```

Restart pacemaker on both nodes and then check the cluster status:

```
root@oattic01:~# crm status
Last updated: Thu Feb  9 12:29:24 2017
Last change: Thu Feb  9 12:28:37 2017 via crm_attribute on oattic01
Stack: corosync
Current DC: oattic01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
7 Resources configured


Online: [ oattic01 oattic02 ]

 vip-slave	(ocf::heartbeat:IPaddr2):	Started oattic01 
 Resource Group: master-group
     vip-master	(ocf::heartbeat:IPaddr2):	Started oattic01 
     vip-rep	(ocf::heartbeat:IPaddr2):	Started oattic01 
 Clone Set: clnPingCheck [pingCheck]
     Started: [ oattic01 oattic02 ]
 Master/Slave Set: msPostgresql [pgsql]
     Masters: [ oattic01 ]
     Slaves: [ oattic02 ]

root@oattic01:~# crm_mon -Qrf1A
Stack: corosync
Current DC: oattic02 (2) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
7 Resources configured


Online: [ oattic01 oattic02 ]

Full list of resources:

 vip-slave	(ocf::heartbeat:IPaddr2):	Started oattic02 
 Resource Group: master-group
     vip-master	(ocf::heartbeat:IPaddr2):	Started oattic01 
     vip-rep	(ocf::heartbeat:IPaddr2):	Started oattic01 
 Clone Set: clnPingCheck [pingCheck]
     Started: [ oattic01 oattic02 ]
 Master/Slave Set: msPostgresql [pgsql]
     Masters: [ oattic01 ]
     Slaves: [ oattic02 ]

Node Attributes:
* Node oattic01:
    + default_ping_set                	: 100       
    + master-pgsql                    	: 1000      
    + pgsql-data-status               	: LATEST    
    + pgsql-master-baseline           	: 000000000C000090
    + pgsql-status                    	: PRI       
* Node oattic02:
    + default_ping_set                	: 100       
    + master-pgsql                    	: 100       
    + pgsql-data-status               	: STREAMING|SYNC
    + pgsql-status                    	: HS:sync   

Migration summary:
* Node oattic01: 
* Node oattic02:
```

Confirm that a recovery file has been created on the Slave server:

```
root@oattic02:~# cat /var/lib/postgresql/9.3/main/recovery.conf
standby_mode = 'on'
primary_conninfo = 'host=10.20.1.200 port=5432 user=postgres application_name=oattic02 keepalives_idle=60 keepalives_interval=5 keepalives_count=5'
restore_command = 'test -f /var/lib/postgresql/9.3/main/pg_archive/%f && cp /var/lib/postgresql/9.3/main/pg_archive/%f %p'
recovery_target_timeline = 'latest'
```

and at the end that the Master and Slave are at the same `xlog` replication:

```
root@oattic01:~# su - postgres
postgres@oattic01:~$ psql
psql (9.3.15)
Type "help" for help.

postgres=# SELECT pg_current_xlog_location();
 pg_current_xlog_location 
--------------------------
 0/5000340
(1 row)

root@oattic02:~# su - postgres
postgres@oattic02:~$ psql 
psql (9.3.15)
Type "help" for help.

postgres=# select pg_last_xlog_replay_location();
 pg_last_xlog_replay_location 
------------------------------
 0/5000340
(1 row)
```

In the Master's log we can see `oattic02` becoming a synchronous replication Slave:

```
2017-02-09 13:43:39 AEDT [3234] @ LOG:  parameter "synchronous_standby_names" changed to "oattic02"
2017-02-09 13:43:41 AEDT [4573] postgres@[unknown] LOG:  standby "oattic02" is now the synchronous standby with priority 1
```

Another check to show the VIP's have been properly created on the Master:

```
root@oattic01:~# ip -f inet addr show | grep -E "UP|inet"
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default 
    inet 127.0.0.1/8 scope host lo
2: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    inet 10.10.1.16/24 brd 10.10.1.255 scope global eth1
3: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    inet 10.20.1.10/24 brd 10.20.1.255 scope global eth2
    inet 10.20.1.200/24 brd 10.20.1.255 scope global secondary eth2
4: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    inet 192.168.0.134/24 brd 192.168.0.255 scope global eth0
    inet 192.168.0.241/24 brd 192.168.0.255 scope global secondary eth0
```

and on the Slave we should only see the cluster read-only VIP attached to the `eth0` interface:

```
root@oattic02:~# ip -f inet addr show | grep -E "UP|inet"
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default 
    inet 127.0.0.1/8 scope host lo
2: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    inet 10.10.1.17/24 brd 10.10.1.255 scope global eth1
3: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    inet 10.20.1.18/24 brd 10.20.1.255 scope global eth2
4: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    inet 192.168.0.135/24 brd 192.168.0.255 scope global eth0
    inet 192.168.0.242/24 brd 192.168.0.255 scope global secondary eth0
```

If any issues try to cleanup affected resource like:

```
root@oattic01:~# crm resource cleanup msPostgresql
```

and if nothing else works reboot both nodes.

## Couple of Tips

In case the Master wouldn't start and the Slave is stuck in DISCONNECT state we can promote the Slave to Master by running:

```
# crm_attribute -l forever -N oattic01 -n "pgsql-data-status" -v "LATEST"
```

where in this case the disconnected slave is on `oattic01`.

Some other gotchas as pointed in the ClusterLabs page (see the links on the top):

PGSQL.lock file (`/var/lib/pgsql/tmp/PGSQL.lock`): The file is created on promote. And it's deleted on demote only if Slave does not exist. If this file remains in a node, it means that the data may be inconsistent. Please copy all data from PRI and delete this lock file.

Stop order: First, stop Slave. After that stop Master. If you stop Master first, PGSQL.lock file remains. If PGSQL would not start on any of the nodes, check for the `PGSQL.lock` file and delete it if present.
