---
type: posts
title: 'VIP(EIP) fail over with Keepalived in Amazon VPC across availability zones'
categories: 
  - High-Availability
tags: [keepalived, haproxy, infrastructure, high-availability, cluster]
---

This example covers VIP failover in AWS VPC across AZ's with Keepalived. The main problem in AWS is that this provider is blocking the `multicast` traffic in the VPC's. To circumvent this we need to switch to unicast for the LVS/IPVS cluster communication. Another issue is the challenge of the virtual environment it self, more specific the VIP failover. In the virtual world it is not enough to move the VIP from one host to another but we also need to inform the physical host Hypervisor platform (Xen,KVM etc) about the change so the traffic can be correctly routed to the new destination via its SDN (Software Defined Network).

The solution of the first problem is using the `unicast_src_ip` and `unicast_peer` options to tell Keepalived to use `unicast` for communication. It does the job but is pretty limiting solution since we need to specify the IP's of the nodes in the setup. For the second one, VIP failover which in case of AWS will be `EIP` (Elastic IP), we need a `notify_master` script which implements this function via AWS CLI utilities.

## Nodes preparation

We have set up two nodes, one in each AZ (Avalibility Zone). The service using the VIP in this case is HAProxy. There are two internal networks in each AZ each of the nodes is connected to. There are routing tables set in the VPC so appropriate subnets can sea each other, one routing table for `10.18.16.0/24` and `10.18.18.0/24` and separate one for `10.18.17.0/24` and `10.18.19.0/24`.


### On host01

The primary network interface eth0 has EIP of `54.226.x.x` associated to it. The internal IP's for both interfaces on this server and the network config are given below:

```
user@host01:~$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 qdisc noqueue state UNKNOWN
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 06:12:0b:e6:d1:86 brd ff:ff:ff:ff:ff:ff
    inet 10.18.16.11/24 brd 10.18.16.255 scope global eth0
    inet6 fe80::412:bff:fee6:d186/64 scope link
       valid_lft forever preferred_lft forever
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 06:27:ca:b8:b1:98 brd ff:ff:ff:ff:ff:ff
    inet 10.18.17.11/24 brd 10.18.17.255 scope global eth1
    inet6 fe80::427:caff:feb8:b198/64 scope link
       valid_lft forever preferred_lft forever
 
user@host01:~$ cat /etc/network/interfaces
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).
 
# The loopback network interface
auto lo
iface lo inet loopback
 
# The primary network interface
auto eth0
iface eth0 inet dhcp
 
auto eth1
iface eth1 inet static
address 10.18.17.11
netmask 255.255.255.0
 
post-up ip route add 10.18.19.0/24 dev eth1 via 10.18.17.1 || true
post-down ip route del 10.18.19.0/24 dev eth1 via 10.18.17.1 || true
```

### On host02

The primary network interface eth0 has EIP of `54.219.x.x` associated to it. The internal IP's for both interfaces on this server and the network config are given below:

```
user@host02:~$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 qdisc noqueue state UNKNOWN
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 02:46:47:62:60:0c brd ff:ff:ff:ff:ff:ff
    inet 10.18.18.11/24 brd 10.18.18.255 scope global eth0
    inet6 fe80::46:47ff:fe62:600c/64 scope link
       valid_lft forever preferred_lft forever
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 02:f3:3f:20:8d:cb brd ff:ff:ff:ff:ff:ff
    inet 10.18.19.11/24 brd 10.18.19.255 scope global eth1
    inet6 fe80::f3:3fff:fe20:8dcb/64 scope link
       valid_lft forever preferred_lft forever
 
user@host02:~$ cat /etc/network/interfaces
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).
 
# The loopback network interface
auto lo
iface lo inet loopback
 
# The primary network interface
auto eth0
iface eth0 inet dhcp
 
auto eth1
iface eth1 inet static
address 10.18.19.11
netmask 255.255.255.0
 
post-up ip route add 10.18.17.0/24 dev eth1 via 10.18.19.1 || true
post-down ip route del 10.18.17.0/24 dev eth1 via 10.18.19.1 || true
```

## Keepalived cluster setup

There is a free EIP `54.192.x.x` available that will be used as VIP for the load balancing. Same as any other VIP scenario this EIP will be floating between the servers depending on which one is in active or passive mode. Except that for services in separate AZ in Amazon moving the VIP between servers is not enough. Since the routing is done by the AWS, the moving of the VIP (the EIP in this case) has to be done via Amazon API so the infrastructure actually knows how and where to route the VIP (read EIP) on switch over. Having this said we need to write a custom script `/etc/keepalived/vrrp.sh` that will do the switch over in Amazon way.

Basically keepalived will be monitoring the local haproxy process and in case of failure on the `MASTER` node, the `BACKUP` node will take over the EIP and become a MASTER it self. The `notify_master` script also re-assigns the old EIP back to the BACKUP server so it can be still accessed remotely. The value of the `virtual_ipaddress` does not matter in this case.

One very important setting is the priority of the VRRP instance which needs to be higher on one of the nodes. In case we have set MASTER and BACKUP state then the MASTER needs to have higher priority. The difference between the priorities of the both nodes has to be lower then the weight of the health check script which is another thing to have in mind. It is very important for making the instance fail over decision.

### On host01

We create new /etc/keepalived/keepalived.conf config file `/etc/keepalived/keepalived.conf`:

```
vrrp_script haproxy-check {
    script "killall -0 haproxy"
    interval 2
    weight 20
}
 
vrrp_instance haproxy-vip {
    state MASTER
    priority 102
    interface eth0
    virtual_router_id 47
    advert_int 3
 
    unicast_src_ip 10.18.16.11
    unicast_peer {
        10.18.18.11
    }
 
    notify_master "/etc/keepalived/vrrp.sh 54.192.x.x start"
 
    virtual_ipaddress {
        10.15.85.31
    }
 
    track_script {
        haproxy-check weight 20
    }
}
```

The API script for EIP switch over `/etc/keepalived/vrrp.sh`:

```
#!/bin/bash
[ -f /etc/keepalived/aws.conf ] && . /etc/keepalived/aws.conf
. /lib/lsb/init-functions
 
ENI_ID="eni-2dxxxxxx"
ALOC_ID="eipalloc-39xxxxxx"
INST_ID="i-acxxxxxx"
ELASTIC_IP=$1
 
case $2 in
    start)
        ec2-associate-address -n $ENI_ID -a $ALOC_ID --allow-reassociation
        echo started
        ;;
    stop)
        #ec2-disassociate-address $ELASTIC_IP
        echo stopped
        ;;
    status)
        ec2-describe-addresses | grep "$ELASTIC_IP" | grep "$INST_ID" > /dev/null
        [ $? -eq 0 ] && echo OK || echo FAIL
        ;;
esac
```

### On host02

We create new /etc/keepalived/keepalived.conf config file `/etc/keepalived/keepalived.conf`:

```
vrrp_script haproxy-check {
    script "killall -0 haproxy"
    interval 2
    weight 20
}
 
vrrp_instance haproxy-vip {
    state BACKUP
    priority 101
    interface eth0
    virtual_router_id 47
    advert_int 3
 
    unicast_src_ip 10.18.18.11
    unicast_peer {
        10.18.16.11
    }
 
    notify_master "/etc/keepalived/vrrp.sh 54.192.x.x start"
 
    virtual_ipaddress {
        10.15.85.31
    }
 
    track_script {
        haproxy-check weight 20
    }
}
```

The API script for EIP switch over `/etc/keepalived/vrrp.sh`:

```
#!/bin/bash
[ -f /etc/keepalived/aws.conf ] && . /etc/keepalived/aws.conf
. /lib/lsb/init-functions
 
ENI_ID="eni-eaxxxxxx"
ALOC_ID="eipalloc-39xxxxxx"
INST_ID="i-72xxxxxx"
ELASTIC_IP=$1
 
case $2 in
    start)
        ec2-associate-address -n $ENI_ID -a $ALOC_ID --allow-reassociation
        echo started
        ;;
    stop)
        #ec2-disassociate-address $ELASTIC_IP
        echo stopped
        ;;
    status)
        ec2-describe-addresses | grep "$ELASTIC_IP" | grep "$INST_ID" > /dev/null
        [ $? -eq 0 ] && echo OK || echo FAIL
        ;;
esac
```

The `/etc/keepalived/aws.conf` file holds the EC2 credentials for a user with limited permissions to associate and describe addresses only.

## References

[Keepalived Github project](https://github.com/acassen/keepalived/blob/master/doc/keepalived.conf.SYNOPSIS)