---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Pacemaker VM cluster fencing in Proxmox PVE with fence_pve'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster, pacemaker]
date: 2017-8-4
---

We can use the `fence_pve` agent to fence/stonith peers in Pacemaker cluster running on VM's in Proxmox PVE host(s). This works and has been tested on `Ubuntu-14.04` with `Pacemaker-1.1.12` from Hastexo PPA repository. Use:

```
$ sudo add-apt-repository ppa:hastexo/ha
```

to add it and then run:

```
$ sudo aptitude update
$ sudo aptitude install pacemaker=1.1.12-0ubuntu2 libcib4 libcrmcluster4 \
  libcrmcommon3 libcrmservice1 liblrmd1 libpe-rules2 libpe-status4 \
  libpengine4 libstonithd2 libtransitioner2 pacemaker-cli-utils
```

to install the needed packages. Accept the solution to remove `libcib3` during the process.

OS and Pacemaker details in the VM's:

```
root@sl01:~# lsb_release -a
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 14.04.5 LTS
Release:    14.04
Codename:   trusty

root@sl01:~# dpkg -l pacemaker | grep ^ii
ii  pacemaker    1.1.12-0ubuntu2   amd64      HA cluster resource manager
```

For the fencing agent I used the current PVE `fence-agents-4.0.20` repository from github:

```
$ wget https://github.com/proxmox/fence-agents-pve/raw/master/fence-agents-4.0.20.tar.gz
$ ./autogen.sh 
$ sudo pip install suds
$ ./configure 
$ make
$ sudo make install
```

The agents are installed under `/usr/sbin/`. To get the resource metadata (the input parameters supported) run:

```
$ /usr/sbin/fence_pve -o metadata
```

Run a manual test to confirm the fence_pve agent is working, here I'll check the status of the two VM's that Pacemaker cluster is runing on:

```
$ /usr/sbin/fence_pve --ip=192.168.0.100 --nodename=virtual --username=root@pam --password=<password> --plug=126 --action=status
Status: ON
$ /usr/sbin/fence_pve --ip=192.168.0.100 --nodename=virtual --username=root@pam --password=<password> --plug=149 --action=status
Status: ON
```

Now we need to set the stonith agent for Pacemaker:

```
$ sudo mkdir -p /usr/lib/stonith/plugins/pve
$ sudo ln -s /usr/sbin/fence_pve /usr/lib/stonith/plugins/pve/fence_pve
```

and configure the primitives (on one of the nodes):

```
primitive p_fence_sl01 stonith:fence_pve \
    params ipaddr="192.168.0.100" inet4_only="true" node_name="virtual" \
           login="root@pam" passwd="<password>" port="126" delay="15" action="reboot" \
    op monitor interval="60s" \
    meta target-role="Started" is-managed="true"
primitive p_fence_sl02 stonith:fence_pve \
    params ipaddr="192.168.0.100" inet4_only="true" node_name="virtual" \
           login="root@pam" passwd="<password>" port="149" action="reboot" \
    op monitor interval="60s" \
    meta target-role="Started" is-managed="true"
location l_fence_sl01 p_fence_sl01 -inf: sl01
location l_fence_sl02 p_fence_sl02 -inf: sl02
```

Now if we check the cluster status:

```
root@sl01:~# crm status
Last updated: Fri Aug  4 13:57:23 2017
Last change: Fri Aug  4 13:56:52 2017 via crmd on sl01
Stack: corosync
Current DC: sl02 (2) - partition with quorum
Version: 1.1.12-561c4cf
2 Nodes configured
10 Resources configured

Online: [ sl01 sl02 ]

 Master/Slave Set: ms_drbd [p_drbd_r0]
     Masters: [ sl01 sl02 ]
 Clone Set: cl_dlm [p_controld]
     Started: [ sl01 sl02 ]
 Clone Set: cl_fs_gfs2 [p_fs_gfs2]
     Started: [ sl01 sl02 ]
 p_fence_sl01   (stonith:fence_pve):    Started sl02 
 p_fence_sl02   (stonith:fence_pve):    Started sl01 
 Clone Set: cl_clvmd [p_clvmd]
     Started: [ sl01 sl02 ]
```

we can see the fencing devices up and ready.

### Testing

I will shutdown corosync on node `sl01` simulating failure and monitor the status of the VM's and the cluster logs on node `sl02`:

```
root@sl02:~# while true; do echo -n "126: " && /usr/sbin/fence_pve --ip=192.168.0.100 --nodename=virtual --username=root@pam --password=<password> --plug=126 --action=status; echo -n "149: " && /usr/sbin/fence_pve --ip=192.168.0.100 --nodename=virtual --username=root@pam --password=<password> --plug=149 --action=status; sleep 1; done
126: Status: ON
149: Status: ON
...
126: Status: ON
149: Status: ON
126: Status: OFF
149: Status: ON
126: Status: ON
^C
root@sl02:~#
```

We can see the `sl01` VM being restarted and in the logs:

```
Aug  4 14:22:04 sl02 corosync[1173]:   [MAIN  ] Completed service synchronization, ready to provide service.
Aug  4 14:22:04 sl02 dlm_controld[22329]: 82908 fence request 1 pid 6631 nodedown time 1501820524 fence_all dlm_stonith
Aug  4 14:22:04 sl02 kernel: [82908.857103] dlm: closing connection to node 1
...
Aug  4 14:22:05 sl02 pengine[1230]:  warning: process_pe_message: Calculated Transition 102: /var/lib/pacemaker/pengine/pe-warn-0.bz2
Aug  4 14:22:05 sl02 crmd[1232]:   notice: te_fence_node: Executing reboot fencing operation (64) on sl01 (timeout=60000)
Aug  4 14:22:05 sl02 crmd[1232]:   notice: te_rsc_command: Initiating action 78: notify p_drbd_r0_pre_notify_demote_0 on sl02 (local)
Aug  4 14:22:05 sl02 stonithd[1227]:   notice: handle_request: Client crmd.1232.44518730 wants to fence (reboot) 'sl01' with device '(any)'
Aug  4 14:22:05 sl02 stonithd[1227]:   notice: initiate_remote_stonith_op: Initiating remote operation reboot for sl01: 9b1fe415-c935-4acf-bb43-6ffd9183e5f8 (0)
Aug  4 14:22:05 sl02 crmd[1232]:   notice: process_lrm_event: Operation p_drbd_r0_notify_0: ok (node=sl02, call=103, rc=0, cib-update=0, confirmed=true)
Aug  4 14:22:06 sl02 stonithd[1227]:   notice: can_fence_host_with_device: p_fence_sl01 can fence (reboot) sl01: dynamic-list
...
Aug  4 14:22:28 sl02 stonithd[1227]:   notice: log_operation: Operation 'reboot' [6684] (call 2 from crmd.1232) for host 'sl01' with device 'p_fence_sl01' returned: 0 (OK)
Aug  4 14:22:28 sl02 stonithd[1227]:  warning: get_xpath_object: No match for //@st_delegate in /st-reply
Aug  4 14:22:28 sl02 stonithd[1227]:   notice: remote_op_done: Operation reboot of sl01 by sl02 for crmd.1232@sl02.9b1fe415: OK
Aug  4 14:22:28 sl02 crmd[1232]:   notice: tengine_stonith_callback: Stonith operation 2/64:102:0:7d571539-fab2-43fe-8574-ebfb48664083: OK (0)
Aug  4 14:22:28 sl02 crmd[1232]:   notice: tengine_stonith_notify: Peer sl01 was terminated (reboot) by sl02 for sl02: OK (ref=9b1fe415-c935-4acf-bb43-6ffd9183e5f8) by client crmd.1232
...
Aug  4 14:22:55 sl02 crm-fence-peer.sh[6913]: INFO peer is fenced, my disk is UpToDate: placed constraint 'drbd-fence-by-handler-r0-ms_drbd'
Aug  4 14:22:55 sl02 kernel: [82959.650435] drbd r0: helper command: /sbin/drbdadm fence-peer r0 exit code 7 (0x700)
Aug  4 14:22:55 sl02 kernel: [82959.650453] drbd r0: fence-peer() = 7 && fencing != Stonith !!!
Aug  4 14:22:55 sl02 kernel: [82959.650549] drbd r0: fence-peer helper returned 7 (peer was stonithed)
...
```

we can see STONITH in operation.
