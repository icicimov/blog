---
type: posts
title: 'MySQL High Availability and Load Balancing with Keepalived'
categories: 
  - High-Availability
  - Database
tags: [mysql, database, infrastructure, high-availability, cluster]
---

What we want to achieve here is have a MySQL HA two nodes cluster in Master-Master mode and load balance the instances using as less hardware as possible. The role of the LB will be given to Keepalived that will be running on the same host as the MySQL instance taking care of the virtual IP and fail over. The scenario is given in the image below: 

![Keepalived](/blog/images/keepalived.jpg "Load balancing and fail over with Keepalived")

***Picture1:** Load balancing and fail over with Keepalived*

If the software talking to MySQL database can take multiple instances as input parameter then the dual master setup is all that we need (taken the above mentioned limitations don't apply). This setup might suit the purpose of Tomcat HA shared sessions storage for example which is simple enough not to cause any issues. I also have MySQL Master-Master mode cluster with circular replication running as Wordpress backend database in production without any issues as well. For others we need to make sure the client writes to one instance only and read from all or in case of slow replication write and read to one instance only and have the second one as standby. That's where keepalived comes into play.

# Setup

The hosts have been setup with two network interfaces, one on a public `192.168.100.0/24` network that will be used for incoming client connections and cluster communication and one on the private `10.10.1.0/24` network that will be used for the replication traffic only. We will start by setting the MySQL service on the nodes first.

## Keepalived

Although we have MySQL replication set as Master-Master we have to insure we write to only one server at all times. We use Keepalived with floating VIP for that purpose. It will elect one of the MySQL backends upon client request and establish permanent connection so all consecutive requests go to the same instance. The following kernel setting are needed before we start:

```
net.ipv4.ip_nonlocal_bind=1
net.ipv4.ip_forward=1
net.ipv4.conf.default.arp_ignore=1
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.log_martians=1
```

that will enable the services, MySQL in this case, to bind to non-local IP address, enable asymmetric routing on the host (requests might come via one interface but leave via another) and set the appropriate ARP level on the network interfaces. Then after installing Keepalived as simple as:

```
$ sudo aptitude install keepalived
```

we need to create the main configuration file `/etc/keepalived/keepalived.conf` on each host. On host01:

```
global_defs {
  lvs_id lvs_host01
  notification_email {
    igorc@encompasscorporation.com
  }
  notification_email_from loadbalancer1
  smtp_server mail.bigpond.com
  smtp_connect_timeout 5
  router_id lb1
}
vrrp_instance VI_1 {
    interface eth0
    state BACKUP
    lvs_sync_daemon_interface eth0
    virtual_router_id 50
    priority 102
    advert_int 3
    track_interface {
      eth0
    }
    authentication {
      auth_type PASS
      auth_pass password
    }
    virtual_ipaddress {
      192.168.100.91 label eth0:1
    }
    notify_master "/etc/keepalived/iptables.sh 192.168.100.91 master"
    notify_backup "/etc/keepalived/iptables.sh 192.168.100.91 backup"
}
virtual_server 192.168.100.91 3306 {
  delay_loop 6
  nopreempt
  lb_algo rr
  lb_kind DR
  protocol TCP
  real_server 192.168.100.89 3306 {
    weight 10
    MISC_CHECK {
      misc_path "/etc/keepalived/mysql-check.sh 192.168.100.89"
      misc_timeout 15
    }
  }
  real_server 192.168.100.90 3306 {
    weight 10
    MISC_CHECK {
      misc_path "/etc/keepalived/mysql-check.sh 192.168.100.90"
      misc_timeout 15
    }
  }
}

On host02:

```
global_defs {
  lvs_id lvs_host02
  notification_email {
    igorc@encompasscorporation.com
  }
  notification_email_from loadbalancer2
  smtp_server mail.bigpond.com
  smtp_connect_timeout 5
  router_id lb2
}
vrrp_instance VI_1 {
    interface eth0
    state BACKUP
    lvs_sync_daemon_interface eth0
    virtual_router_id 50
    priority 101
    advert_int 3
    track_interface {
      eth0
    }
    authentication {
      auth_type PASS
      auth_pass password
    }
    virtual_ipaddress {
      192.168.100.91 label eth0:1
    }
    notify_master "/etc/keepalived/iptables.sh 192.168.100.91 master"
    notify_backup "/etc/keepalived/iptables.sh 192.168.100.91 backup"
}
virtual_server 192.168.100.91 3306 {
  delay_loop 6
  nopreempt
  lb_algo rr
  lb_kind DR
  protocol TCP
  real_server 192.168.100.89 3306 {
    weight 10
    MISC_CHECK {
      misc_path "/etc/keepalived/mysql-check.sh 192.168.100.89"
      misc_timeout 15
    }
  }
  real_server 192.168.100.90 3306 {
    weight 10
    MISC_CHECK {
      misc_path "/etc/keepalived/mysql-check.sh 192.168.100.90"
      misc_timeout 15
    }
  }
}

Set the health check user we will use in Keepalived mysql script on one of the hosts (the change will get replicated to the other one):

```
mysql> grant select on *.* to 'hcheck'@'localhost' identified by 'password';
Query OK, 0 rows affected (0.00 sec)
 
mysql> grant select on *.* to 'hcheck'@'192.168.100.89' identified by 'password';
Query OK, 0 rows affected (0.00 sec)
 
mysql> grant select on *.* to 'hcheck'@'192.168.100.90' identified by 'password';
Query OK, 0 rows affected (0.00 sec)
 
mysql> flush privileges;
Query OK, 0 rows affected (0.00 sec)
```

Next we set a simple health check script `/etc/keepalived/mysql-check.sh` on both hosts. We don't want to just check the TCP connection to port 3306 but also check if the server is alive and responding:

```bash
#!/bin/bash
mysql --host=$1 --user=hcheck --password=password -Nse "select 1 from dual"
```

Another point we need to solve is the port redirect on the backup server. On the backup server MySQL needs to serve requests coming to the VIP which does not exist on this box. To solve this we set redirect rule on the firewall:

```
$ sudo iptables -t nat -A PREROUTING -d 192.168.100.91 -p tcp -j REDIRECT
```

We need to do this automatically on fail over and startup so we modify our config little bit. On both servers we create the following script `/etc/keepalived/iptables.sh`:

```bash
#!/bin/bash
case $2 in
backup)
/sbin/iptables -t nat -A PREROUTING -d $1 -p tcp -j REDIRECT
;;
master)
/sbin/iptables -t nat -D PREROUTING -d $1 -p tcp -j REDIRECT
;;
esac
```

and tell the LB to execute it on fail over as we did in the above configuration file. This script will add the firewall rule on the BACKUP node and remove it on the MASTER one.

That's it, both servers are setup as a load balancers listening on VIP and sending the incoming traffic only to the host that the VIP is bound to (effect of `lb_kind DR`). We have HA for the MySQL database and the LB its self, in case the MASTER fails the VIP will move to the BACKUP one which will take over the VIP and the MASTER role.

```
# ipvsadm -Ln
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  192.168.100.91:3306 rr
  -> 192.168.100.89:3306          Route   10     1          0        
  -> 192.168.100.90:3306          Route   10     2          0
```
 
## Testing

We need to test couple of scenarios for HA and failover.

### MySQL instance failure

In case one of the MySQL db's fails the LVS LB will detect that and remove that instance from the LB route:

```
Sep 23 09:35:44 host02 Keepalived_healthcheckers: Misc check to [192.168.100.89] for [/etc/keepalived/mysql-check.sh 192.168.100.89] failed.
Sep 23 09:35:44 host02 Keepalived_healthcheckers: Removing service [192.168.100.89]:3306 from VS [192.168.100.91]:3306
```

which we can see in the VS routing table as well:

```
root@host01:~# ipvsadm -Ln
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
-> RemoteAddress:Port Forward Weight ActiveConn InActConn
TCP 192.168.100.91:3306 rr
-> 192.168.100.90:3306 Route 10 1 0
```

and when it comes back:

```
Sep 23 10:58:40 host02 Keepalived_healthcheckers: Misc check to [192.168.100.89] for [/etc/keepalived/mysql-check.sh 192.168.100.89] success.
Sep 23 10:58:40 host02 Keepalived_healthcheckers: Adding service [192.168.100.89]:3306 to VS [192.168.100.91]:3306
```

The failover on the client side will look like this:

```
mysql> show tables;
ERROR 2006 (HY000): MySQL server has gone away
No connection. Trying to reconnect...
Connection id: 60
Current database: sessions
+--------------------+
| Tables_in_sessions |
+--------------------+
| tomcat_sessions |
+--------------------+
1 row in set (0.03 sec)
mysql>
```

In case of the MySQL client, the client retries the connection and reconnects to the other server by itself. In case of some custom client, the client should be able to do the same ie keep retrying the connection until it succeeds.

### LVS MASTER failure

In case the MASTER node fails, simulating by stopping the Keepalived service:

```
root@host01:~# service keepalived stop
```

the BACKUP takes the role of MASTER:

```
Sep 23 11:10:01 host02 Keepalived_vrrp: VRRP_Instance(VI_1) Transition to MASTER STATE
Sep 23 11:10:04 host02 Keepalived_vrrp: VRRP_Instance(VI_1) Entering MASTER STATE
Sep 23 11:10:04 host02 Keepalived_vrrp: Opening script file /etc/keepalived/iptables.sh
```

takes over the VIP and removes the firewall rule by executing the `/etc/keepalived/iptables.sh` script:

```
root@host02:~# iptables -t nat -nvL
Chain PREROUTING (policy ACCEPT 34 packets, 3046 bytes)
pkts bytes target prot opt in out source destination
 
Chain INPUT (policy ACCEPT 2 packets, 128 bytes)
pkts bytes target prot opt in out source destination
 
Chain OUTPUT (policy ACCEPT 52 packets, 3144 bytes)
pkts bytes target prot opt in out source destination
 
Chain POSTROUTING (policy ACCEPT 52 packets, 3144 bytes)
pkts bytes target prot opt in out source destination
```

so the client will reconnect after renewing the connection to the db:

```
mysql> show tables;
ERROR 2013 (HY000): Lost connection to MySQL server during query
mysql> show tables;
ERROR 2006 (HY000): MySQL server has gone away
No connection. Trying to reconnect...
Connection id: 153
Current database: sessions
+--------------------+
| Tables_in_sessions |
+--------------------+
| tomcat_sessions |
+--------------------+
1 row in set (0.19 sec)
```

And when the old MASTER rejoins the cluster it takes the role of BACKUP which is exactly what we want in order to avoid the flip-flop effect and interrupt the clients again (the nopreempt option in our config):

```
root@host01:~# service keepalived start
[ ok ] Starting keepalived: keepalived.
```

on the current MASTER we will see:

```
root@host02:~# tail -f /var/log/syslog
...
Sep 23 11:15:49 host02 kernel: [79474.736124] IPVS: sync thread started: state = BACKUP, mcast_ifn = eth0, syncid = 50
```

## Making it work on AWS

The main problem in AWS is that this provider is blocking the multicast traffic in the VPC's. To circumvent this we need to switch to unicast for the LVS/IPVS cluster communication. Another issue is the challenge of the virtual environment it self, more specific the VIP failover. In the virtual world it is not enough to move the VIP from one host to another but we also need to inform the physical host Hypervisor platform (Xen,KVM etc) about the change so the traffic can be correctly routed to the new destination via its SDN (Software Defined Network).

The solution of the first problem is using the `unicast_src_ip` and `unicast_peer options` to tell Keepalived to use unicast for communication. For the second one, VIP failover which in case of AWS will be EIP, we need to modify the notify_master script and implement this function via AWS CLI utilities. The technical details of this setup can be found in VIP(EIP) fail over with Keepalived in Amazon VPC across availability zones