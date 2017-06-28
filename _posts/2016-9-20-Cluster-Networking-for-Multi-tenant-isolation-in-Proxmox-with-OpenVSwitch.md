---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Cluster Networking for Multi-tenant isolation in Proxmox with OpenVSwitch'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster, iscsi, ovs]
date: 2016-9-22
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
---

This is probably the most complex part of the setup. It involves network configuration of the cluster in a way that the instances running on different nodes can still talk to each other. This is needed in order to provide clustering and HA of the VM services them self.

Note that the config below can be done via PVE GUI as well but I prefer the manual approach. The networking on the nodes has been setup (`/etc/network/interfaces` file as per usual) as shown below:

```
# Internal networks
auto eth1
iface eth1 inet static
    address  10.10.1.185
    netmask  255.255.255.0
    metric 200
 
auto eth2
iface eth2 inet static
    address  10.20.1.185
    netmask  255.255.255.0
    metric 200
 
# External network
iface eth0 inet manual
auto vmbr0
iface vmbr0 inet static
    address  192.168.0.185
    netmask  255.255.255.0
    gateway  192.168.0.1
    bridge_ports eth0
    bridge_stp off
    bridge_fd 0
    metric 100
```

Since the cluster nodes are going to be deployed in the provider's infrastructure of we have no control at all, lets say physical switches to setup VLAN's on, we need to come up with some kind of SDN ie L3 overlay network which we can configure according to our needs. One such solution is using `OpenVSwitch` and `GRE` or `VxLAN` overlay networks (tunnels) which resulted in me creating the following configuration under `/etc/network/interfaces` on both nodes:

```
# GRE/VXLAN network
allow-vmbr1 eth3
iface eth3 inet manual
        ovs_bridge vmbr1
        ovs_type OVSPort
        mtu 1546
        up ip link set eth3 up
 
# GRE/VXLAN bridge
auto vmbr1
allow-ovs vmbr1
iface vmbr1 inet manual
        ovs_type OVSBridge
        ovs_ports eth3 tep0
        up ip link set vmbr1 up
 
# GRE/VXLAN interface
allow-vmbr1 tep0
iface tep0 inet static
        ovs_bridge vmbr1
        ovs_type OVSIntPort
        #ovs_options tag=11
        address 10.30.1.185
        netmask 255.255.255.0
 
# Integration bridge
auto vmbr2
allow-ovs vmbr2
iface vmbr2 inet manual
    ovs_type OVSBridge
    ovs_ports vx1 dhcptap0
    up ip link set vmbr2 up
 
# GRE/VXLAN tunnel
allow-vmbr2 vx1
iface vx1 inet manual
    ovs_type OVSTunnel
    ovs_bridge vmbr2
    ovs_tunnel_type vxlan
    ovs_options trunks=11,22,33
    ovs_tunnel_options options:remote_ip=10.30.1.186 options:key=flow options:dst_port=4789
 
# DHCP server interface for VLAN-11
allow-vmbr2 dhcptap0
iface dhcptap0 inet static
        ovs_bridge vmbr2
        ovs_type OVSIntPort
        ovs_options tag=11
        address 172.29.240.3
        netmask 255.255.255.0
```

and on proxmox02:

```
# GRE/VXLAN network
allow-vmbr1 eth3
iface eth3 inet manual
        ovs_bridge vmbr1
        ovs_type OVSPort
        mtu 1546
        up ip link set eth3 up
 
# GRE/VXLAN bridge
auto vmbr1
allow-ovs vmbr1
iface vmbr1 inet manual
        ovs_type OVSBridge
        ovs_ports eth3 tep0
        up ip link set vmbr1 up
 
# GRE/VXLAN interface
allow-vmbr1 tep0
iface tep0 inet static
        ovs_bridge vmbr1
        ovs_type OVSIntPort
        #ovs_options tag=11
        address 10.30.1.186
        netmask 255.255.255.0
 
# Integration bridge
auto vmbr2
allow-ovs vmbr2
iface vmbr2 inet manual
    ovs_type OVSBridge
    ovs_ports vx1 dhcptap0
    up ip link set vmbr2 up
 
# GRE/VXLAN tunnel
allow-vmbr2 vx1
iface vx1 inet manual
    ovs_type OVSTunnel
    ovs_bridge vmbr2
    ovs_tunnel_type vxlan
    ovs_options trunks=11,22,33
    ovs_tunnel_options options:remote_ip=10.30.1.185 options:key=flow options:dst_port=4789
```

The only limitation is the name of the OVS bridges which needs to be of format `vmbrX` where X is a digit, so the bridge gets recognized and activated in PVE. I have used `VxLAN` since it is most recent and more efficient tunneling type and adds less packet overhead compared to `GRE`. The major difference is though that VxLAN uses UDP (port 4789 by default), so nearly all routers properly distribute traffic to the next hop by hashing over the 5 tuple that include the UDP source and destination ports. I have used the network interface `eth3` as physical transport for the tunnel and moved its address to the virtual interface `tep0` which is a internal port for the OVS bridge `vmbr1`. Attaching the IP to a port instead of the bridge itself makes it possible to attach more than one network to this bridge. This makes the nodes IP's on this network, `10.30.1.185` on `proxmox01` and `10.30.1.186` on `proxmox02`, become the endpoints of our VxLAN tunnel. 

The next part is the OVS bridge `vmbr2`. This is the bridge that holds the VxLAN end point interface `vx1` on each side and the bridge that every VM launched gets connected to in order to be able to communicate with its peers running on the other node. This VxLAN tunnel can hold many different VLAN's each marked with its own dedicated tag in OVS which takes care of the routing flows and traffic separation so the VLAN's stay isolated from each other. In this case I have limited the tags to 11, 22 and 33 meaning I want to have only 3 different networks in my setup.

**NOTE:** VxLAN by default needs multicast enabled on the network which often is not available on the cloud providers like AWS lets say. In this case we use `unicast` by specifying the IP's of the endpoints.

**NOTE:** Both GRE and VxLAN do network encapsulation but do not provide encryption thus they are best suited for private LAN usage. In case of WAN an additional tool providing encryption needs to be used, ie some VPN option like OpenVPN, IPSEC or PeerVPN, in order to protect sensitive traffic.

After networking restart this is the OVS structure we've got created:

```
root@proxmox01:~# ovs-vsctl show
f463d896-7fcb-40b1-b4a1-e493b255d978
    Bridge "vmbr2"
        Port "vmbr2"
            Interface "vmbr2"
                type: internal
        Port "vx1"
            trunks: [11, 22, 33]
            Interface "vx1"
                type: vxlan
                options: {dst_port="4789", key=flow, remote_ip="10.30.1.186"}
    Bridge "vmbr1"
        Port "eth3"
            Interface "eth3"
        Port "vmbr1"
            Interface "vmbr1"
                type: internal
        Port "tep0"
            Interface "tep0"
                type: internal
    ovs_version: "2.3.0"
```

and on node proxmox02:

```
root@proxmox02:~# ovs-vsctl show
76ca2f71-3963-4a65-beb9-cc5807cf9a17
    Bridge "vmbr2"
        Port "vmbr2"
            Interface "vmbr2"
                type: internal
        Port "vx1"
            trunks: [11, 22, 33]
            Interface "vx1"
                type: vxlan
                options: {dst_port="4789", key=flow, remote_ip="10.30.1.185"}
    Bridge "vmbr1"
        Port "tep0"
            Interface "tep0"
                type: internal
        Port "vmbr1"
            Interface "vmbr1"
                type: internal
        Port "eth3"
            Interface "eth3"
    ovs_version: "2.3.0"
```

The network bridges, ports and interfaces will also appear in PVE and can be seen in the `Networking` tab of the GUI.

Then I went and launched two test LXC containers, one on each node, and connected both to the `vmbr2`. Each container was created with two network interfaces, one tagged with tag 11 and the other with tag 22. Now we can see some new interfaces added by PVE to `vmbr2` and tagged by the appropriate tags. On the first node where `lxc01` (PVE instance id 100) was launched :

```
root@proxmox01:~# ovs-vsctl show
f463d896-7fcb-40b1-b4a1-e493b255d978
    Bridge "vmbr2"
        Port "vmbr2"
            Interface "vmbr2"
                type: internal
        Port "dhcptap0"
            tag: 11
            Interface "dhcptap0"
                type: internal
        Port "veth100i1"
            tag: 11
            Interface "veth100i1"
        Port "veth100i2"
            tag: 22
            Interface "veth100i2"
        Port "vx1"
            trunks: [11, 22, 33]
            Interface "vx1"
                type: vxlan
                options: {dst_port="4789", key=flow, remote_ip="10.30.1.186"}
    Bridge "vmbr1"
        Port "eth3"
            Interface "eth3"
        Port "vmbr1"
            Interface "vmbr1"
                type: internal
        Port "tep0"
            Interface "tep0"
                type: internal
    ovs_version: "2.3.0"
```

we have `veth100i1` and `veth100i2` created and on `proxmox02` we have `veth101i1` and `veth102i2` created:

```
root@proxmox02:~# ovs-vsctl show
76ca2f71-3963-4a65-beb9-cc5807cf9a17
    Bridge "vmbr2"
        Port "vmbr2"
            Interface "vmbr2"
                type: internal
        Port "veth101i1"
            tag: 11
            Interface "veth101i1"
        Port "dhcptap0"
            tag: 11
            Interface "dhcptap0"
                type: internal
        Port "vx1"
            trunks: [11, 22, 33]
            Interface "vx1"
                type: vxlan
                options: {dst_port="4789", key=flow, remote_ip="10.30.1.185"}
        Port "veth101i2"
            tag: 22
            Interface "veth101i2"
    Bridge "vmbr1"
        Port "tep0"
            Interface "tep0"
                type: internal
        Port "vmbr1"
            Interface "vmbr1"
                type: internal
        Port "eth3"
            Interface "eth3"
    ovs_version: "2.3.0"
```

The PVE built-in OVS integration is working great as we can see. Now if we login to the containers and check the connectivity:

```
root@lxc01:~# ip addr show eth2     
46: eth2@if47: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 66:30:65:66:62:64 brd ff:ff:ff:ff:ff:ff
    inet 172.29.250.10/24 brd 172.29.250.255 scope global eth2
       valid_lft forever preferred_lft forever
    inet6 fe80::6430:65ff:fe66:6264/64 scope link
       valid_lft forever preferred_lft forever
 
root@lxc02:~# ip addr show eth2
34: eth2@if35: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 62:37:61:63:65:64 brd ff:ff:ff:ff:ff:ff
    inet 172.29.250.11/24 brd 172.29.250.255 scope global eth2
       valid_lft forever preferred_lft forever
    inet6 fe80::6037:61ff:fe63:6564/64 scope link
       valid_lft forever preferred_lft forever
 
root@lxc01:~# ping -c 4 172.29.250.11
PING 172.29.250.11 (172.29.250.11) 56(84) bytes of data.
64 bytes from 172.29.250.11: icmp_seq=1 ttl=64 time=1.30 ms
64 bytes from 172.29.250.11: icmp_seq=2 ttl=64 time=0.952 ms
64 bytes from 172.29.250.11: icmp_seq=3 ttl=64 time=0.503 ms
64 bytes from 172.29.250.11: icmp_seq=4 ttl=64 time=0.545 ms
--- 172.29.250.11 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3001ms
rtt min/avg/max/mdev = 0.503/0.826/1.307/0.329 ms
 
root@lxc02:~# ping -c 4 172.29.250.10
PING 172.29.250.10 (172.29.250.10) 56(84) bytes of data.
64 bytes from 172.29.250.10: icmp_seq=1 ttl=64 time=1.63 ms
64 bytes from 172.29.250.10: icmp_seq=2 ttl=64 time=0.493 ms
64 bytes from 172.29.250.10: icmp_seq=3 ttl=64 time=0.525 ms
64 bytes from 172.29.250.10: icmp_seq=4 ttl=64 time=0.510 ms
--- 172.29.250.10 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3071ms
rtt min/avg/max/mdev = 0.493/0.791/1.637/0.488 ms
```

the containers on the `172.29.250.0/24` network can see each other although running on two different nodes. Now to the last part of the setup ... the DHCP.

## Providing DHCP service to the VM networks

All the above is fine as long as we configure our VM's with static IP's matching the VLAN they are connecting to. But what if we just want to launch the VM and don't care about the IP it gets? PVE it self has an option to launch the VM with DHCP instead of static IP but the thing is it does not provide the DHCP service it self. The reason is probably the complexity involved in supporting the DHCP service in HA setup, first there can be only a single instance of DHCP service running for a given VLAN at any given time and second if the node DHCP is running on crashes the service needs to be moved to the second node. I decided to solve this challenge using `dnsmasq` and `keepalived`. I added the following interface to both PVE nodes in `/etc/network/interfaces`:

```
# DHCP server interface for VLAN-11
allow-vmbr2 dhcptap0
iface dhcptap0 inet static
        ovs_bridge vmbr2
        ovs_type OVSIntPort
        ovs_options tag=11
        address 172.29.240.3
        netmask 255.255.255.0
```

Then configured keepalived in `/etc/keepalived/keepalived.conf` to manage a floating VIP on this interface and attach a dnsmasq service configured as DHCP service for the VLAN (in this case the one tagged with 11):

```
global_defs {
   notification_email {
     igorc@encompasscorporation.com
   }
   notification_email_from proxmox01
   smtp_server localhost
   smtp_connect_timeout 30
   lvs_id dnsmasq
}
 
vrrp_script dnsmasq-dhcptap0 {
    script "kill -0 $(cat /var/run/dnsmasq/dnsmasq-dhcptap0.pid)"
    interval 2
    fall 2     
    rise 2
    weight 20
}
 
vrrp_instance dnsmasq-dhcptap0 {
    state BACKUP
    priority 102
    interface vmbr0
    virtual_router_id 47
    advert_int 3
    lvs_sync_daemon_interface eth2
    nopreempt
 
    unicast_src_ip 192.168.0.185
    unicast_peer {
        192.168.0.186
    }
  
    notify_master "/etc/keepalived/dnsmasq.sh start dhcptap0 proxmox02"
    notify_backup "/etc/keepalived/dnsmasq.sh stop dhcptap0"
    smtp_alert
  
    virtual_ipaddress {
        172.29.240.3/24 dev dhcptap0 scope global
    }
 
    virtual_routes {
        172.29.240.0/24 dev dhcptap0
    }
 
    track_script {
        dnsmasq-dhcptap0
    }
 
    track_interface {
        eth2
        dhcptap0
    }
}
```

on the second node proxmox02:

```
global_defs {
   notification_email {
     igorc@encompasscorporation.com
   }
   notification_email_from proxmox02
   smtp_server localhost
   smtp_connect_timeout 30
   lvs_id dnsmasq
}
 
vrrp_script dnsmasq-dhcptap0 {
    script "kill -0 $(cat /var/run/dnsmasq/dnsmasq-dhcptap0.pid)"
    interval 2
    fall 2      
    rise 2
    weight 20
}
 
vrrp_instance dnsmasq-dhcptap0 {
    state BACKUP
    priority 101
    interface vmbr0
    virtual_router_id 47
    advert_int 3
    lvs_sync_daemon_interface eth2
    nopreempt
    garp_master_delay 1
  
    unicast_src_ip 192.168.0.186
    unicast_peer {
        192.168.0.185
    }
  
    notify_master "/etc/keepalived/dnsmasq.sh start dhcptap0 proxmox01"
    notify_backup "/etc/keepalived/dnsmasq.sh stop dhcptap0"
    smtp_alert
  
    virtual_ipaddress {
        172.29.240.3/24 dev dhcptap0 scope global
    }
 
    virtual_routes {
        172.29.240.0/24 dev dhcptap0
    }
 
    track_script {
        dnsmasq-dhcptap0
    }
 
    track_interface {
        eth1
        dhcptap0
    }
}
```

On startup, keepalived will promote to `MASTER` on one of the nodes and to `BACKUP` on the other. The MASTER node will then run the `/etc/keepalived/dnsmasq.sh` script:

```
#!/bin/bash
CRONFILE="/var/spool/cron/crontabs/root"
LEASEFILE="/var/run/dnsmasq/dnsmasq-${2}.leases"
PIDFILE="/var/run/dnsmasq/dnsmasq-${2}.pid"
case "$1" in
  start)
         [[ ! -d /var/run/dnsmasq ]] && mkdir -p /var/run/dnsmasq
         /sbin/ip link set dev ${2} up && \
         /usr/sbin/dnsmasq -u root --conf-file=/etc/dnsmasq.d/dnsmasq-${2} && \
         [[ $(grep -c ${2} $CRONFILE) -eq 0 ]] && echo "* * * * * /usr/bin/scp $LEASEFILE ${3}:$LEASEFILE" | tee -a $CRONFILE
         ssh $3 "cat $PIDFILE | xargs kill -15"
         ssh $3 "sed -i '/dnsmasq-${2}.leases/d' $CRONFILE"
         /bin/kill -0 $(< $PIDFILE) && exit 0 || echo "Failed to start dnsmasq for $2."
         ;;
   stop)
         sed -i '/dnsmasq-${2}.leases/d' $CRONFILE || echo "Failed to remove cronjob for $2 leases sync."
         #sed -n -i '/dnsmasq-${2}.leases/d' /var/spool/cron/crontabs/root
         [[ -f "$PIDFILE" ]] && /bin/kill -15 $(< $PIDFILE) && exit 0 || echo "Failed to stop dnsmasq for $2 or process doesn't exist."
         ;;
      *)
         echo "Usage: $0 [start|stop] interface_name peer_hostname"
esac
exit 1
```

which will activate the `dhcptap0` OVS port interface on `vmbr2`, start a dnsmasq DHCP process, that will load its configuration from `/etc/dnsmasq.d/dnsmasq-dhcptap0`, and attach it to `dhcptap0`. Lastly it will create a cron job which will constantly copy the DHCP leases to the standby node so in case of takeover that node has the list of IP's that have already been dedicated. The DHCP config file `/etc/dnsmasq.d/dnsmasq-dhcptap0` looks like this:

```
strict-order
bind-interfaces
interface=dhcptap0
pid-file=/var/run/dnsmasq/dnsmasq-dhcptap0.pid
listen-address=172.29.240.3
except-interface=lo
dhcp-range=172.29.240.128,172.29.240.254,12h
dhcp-leasefile=/var/run/dnsmasq/dnsmasq-dhcptap0.leases
```

Upon takeover, the script will also send an email to a dedicated address to let us know that switch over had occur. Of course the script needs to be executable:

```
# chmod +x /etc/keepalived/dnsmasq.sh
```

And we also disable the dnsmasq daemon in `/etc/default/dnsmasq` since we want to start multiple processes manually when needed:

```
[...]
ENABLED=0
[...]
```

In case we need debugging we can add:

```
[...]
DAEMON_ARGS="-D
[...]
```

to the config as well.

Then I have configured `eth1` as DHCP interface on `lxc01` and `lxc02` and after bringing up the interfaces I checked the keepalived status:

```
root@proxmox02:~# systemctl status keepalived.service
 keepalived.service - LSB: Starts keepalived
   Loaded: loaded (/etc/init.d/keepalived)
   Active: active (running) since Tue 2016-03-15 14:57:17 AEDT; 2 weeks 0 days ago
  Process: 18834 ExecStop=/etc/init.d/keepalived stop (code=exited, status=0/SUCCESS)
  Process: 19542 ExecStart=/etc/init.d/keepalived start (code=exited, status=0/SUCCESS)
   CGroup: /system.slice/keepalived.service
           ├─19545 /usr/sbin/keepalived -D
           ├─19546 /usr/sbin/keepalived -D
           ├─19547 /usr/sbin/keepalived -D
           └─20072 /usr/sbin/dnsmasq -u root --conf-file=/etc/dnsmasq.d/dnsmasq-dhcptap0
Mar 30 03:55:53 proxmox02 dnsmasq-dhcp[20072]: DHCPREQUEST(dhcptap0) 172.29.240.192 62:36:35:61:62:33
Mar 30 03:55:53 proxmox02 dnsmasq-dhcp[20072]: DHCPACK(dhcptap0) 172.29.240.192 62:36:35:61:62:33 lxc02
Mar 30 06:39:58 proxmox02 dnsmasq-dhcp[20072]: DHCPREQUEST(dhcptap0) 172.29.240.176 3a:64:63:36:34:39
Mar 30 06:39:58 proxmox02 dnsmasq-dhcp[20072]: DHCPACK(dhcptap0) 172.29.240.176 3a:64:63:36:34:39 lxc01
Mar 30 08:59:47 proxmox02 dnsmasq-dhcp[20072]: DHCPREQUEST(dhcptap0) 172.29.240.192 62:36:35:61:62:33
Mar 30 08:59:47 proxmox02 dnsmasq-dhcp[20072]: DHCPACK(dhcptap0) 172.29.240.192 62:36:35:61:62:33 lxc02
Mar 30 11:27:56 proxmox02 dnsmasq-dhcp[20072]: DHCPREQUEST(dhcptap0) 172.29.240.176 3a:64:63:36:34:39
Mar 30 11:27:56 proxmox02 dnsmasq-dhcp[20072]: DHCPACK(dhcptap0) 172.29.240.176 3a:64:63:36:34:39 lxc01
Mar 30 13:17:30 proxmox02 dnsmasq-dhcp[20072]: DHCPREQUEST(dhcptap0) 172.29.240.192 62:36:35:61:62:33
Mar 30 13:17:30 proxmox02 dnsmasq-dhcp[20072]: DHCPACK(dhcptap0) 172.29.240.192 62:36:35:61:62:33 lxc02
```

we can see the requests coming through and the leases file populated and in sync on both nodes:

```
root@proxmox02:~# cat /var/run/dnsmasq/dnsmasq-dhcptap0.leases
1462198134 3a:64:63:36:34:39 172.29.240.176 lxc01 *
1462195647 62:36:35:61:62:33 172.29.240.192 lxc02 *
 
root@proxmox01:~# cat /var/run/dnsmasq/dnsmasq-dhcptap0.leases
1462198134 3a:64:63:36:34:39 172.29.240.176 lxc01 *
1462195647 62:36:35:61:62:33 172.29.240.192 lxc02 *
```

thanks to the cronjob set on the master node:

```
root@proxmox02:~# crontab -l | grep -v ^\#
* * * * * /usr/bin/scp /var/run/dnsmasq/dnsmasq-dhcptap0.leases proxmox01:/var/run/dnsmasq/dnsmasq-dhcptap0.leases
```

The script moves the job to the new `MASTER` upon fail-over. For the end we test the connectivity from the containers to confirm all is working well:

```
root@lxc01:~# ip addr show eth1
48: eth1@if49: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 3a:64:63:36:34:39 brd ff:ff:ff:ff:ff:ff
    inet 172.29.240.176/24 brd 172.29.240.255 scope global eth1
       valid_lft forever preferred_lft forever
    inet6 fe80::3864:63ff:fe36:3439/64 scope link
       valid_lft forever preferred_lft forever
 
root@lxc02:~# ip addr show eth1
30: eth1@if31: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 62:36:35:61:62:33 brd ff:ff:ff:ff:ff:ff
    inet 172.29.240.192/24 brd 172.29.240.255 scope global eth1
       valid_lft forever preferred_lft forever
    inet6 fe80::6036:35ff:fe61:6233/64 scope link
       valid_lft forever preferred_lft forever
 
root@lxc01:~# ping -c 4 172.29.240.192  
PING 172.29.240.192 (172.29.240.192) 56(84) bytes of data.
64 bytes from 172.29.240.192: icmp_seq=1 ttl=64 time=1.30 ms
64 bytes from 172.29.240.192: icmp_seq=2 ttl=64 time=0.906 ms
64 bytes from 172.29.240.192: icmp_seq=3 ttl=64 time=0.591 ms
64 bytes from 172.29.240.192: icmp_seq=4 ttl=64 time=0.672 ms
--- 172.29.240.192 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3040ms
rtt min/avg/max/mdev = 0.591/0.869/1.309/0.280 ms
 
root@lxc02:~# ping -c 4 172.29.240.176  
PING 172.29.240.176 (172.29.240.176) 56(84) bytes of data.
64 bytes from 172.29.240.176: icmp_seq=1 ttl=64 time=1.23 ms
64 bytes from 172.29.240.176: icmp_seq=2 ttl=64 time=0.583 ms
64 bytes from 172.29.240.176: icmp_seq=3 ttl=64 time=0.622 ms
64 bytes from 172.29.240.176: icmp_seq=4 ttl=64 time=0.554 ms
--- 172.29.240.176 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 2999ms
rtt min/avg/max/mdev = 0.554/0.748/1.233/0.281 ms
```

## Network Isolation

As mentioned previously, this setup offers the benefit of network isolation meaning, as per our config, the VM's attached to VLAN-11 for example will not be able to talk to the ones attached to VLAN-22. This means these VLAN's can be given to different tenants and they will not be able to see each other traffic although both of them are using the same SDN. This is courtesy of the `VxLAN` tunnel properties (and `GRE` as well for that matter) of `L2` tagging.

To test this I have added new interface eth3 on both containers and set its IP in the same subnet as interface eth2 but with different tag of 33:

```
root@lxc01:~# ip addr show eth2
46: eth2@if47: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 66:30:65:66:62:64 brd ff:ff:ff:ff:ff:ff
    inet 172.29.250.10/24 brd 172.29.250.255 scope global eth2
       valid_lft forever preferred_lft forever
    inet6 fe80::6430:65ff:fe66:6264/64 scope link
       valid_lft forever preferred_lft forever
 
root@lxc01:~# ip addr show eth3
57: eth3@if58: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 36:32:66:37:62:39 brd ff:ff:ff:ff:ff:ff
    inet 172.29.250.13/24 scope global eth3
       valid_lft forever preferred_lft forever
    inet6 fe80::3432:66ff:fe37:6239/64 scope link
       valid_lft forever preferred_lft forever
```

Now, if I try to ping `172.29.250.10` or `172.29.250.11` (on proxmox02) from `172.29.250.10`:

```
root@lxc01:~# ping -c 4 -W 5 -I eth3 172.29.250.10
PING 172.29.250.10 (172.29.250.10) from 172.29.250.13 eth3: 56(84) bytes of data.
From 172.29.250.13 icmp_seq=1 Destination Host Unreachable
From 172.29.250.13 icmp_seq=2 Destination Host Unreachable
From 172.29.250.13 icmp_seq=3 Destination Host Unreachable
From 172.29.250.13 icmp_seq=4 Destination Host Unreachable
--- 172.29.250.10 ping statistics ---
4 packets transmitted, 0 received, +4 errors, 100% packet loss, time 3016ms
pipe 3
 
root@lxc01:~# ping -c 4 -W 5 -I eth3 172.29.250.11
PING 172.29.250.11 (172.29.250.11) from 172.29.250.13 eth3: 56(84) bytes of data.
From 172.29.250.13 icmp_seq=1 Destination Host Unreachable
From 172.29.250.13 icmp_seq=2 Destination Host Unreachable
From 172.29.250.13 icmp_seq=3 Destination Host Unreachable
From 172.29.250.13 icmp_seq=4 Destination Host Unreachable
--- 172.29.250.11 ping statistics ---
4 packets transmitted, 0 received, +4 errors, 100% packet loss, time 2999ms
pipe 4
```

we can see the connectivity is failing. Although the interfaces belong to the same `L3` class network they have been isolated on `L2` layer in the SDN and thus exist as separate networks.

{% include series.html %}