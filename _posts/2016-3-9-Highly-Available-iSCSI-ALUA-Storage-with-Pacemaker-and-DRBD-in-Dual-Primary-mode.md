---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Highly Available iSCSI ALUA (Asymetric Logical Unit Access) Storage with Pacemaker and DRBD in Dual-Primary mode - Part1'
categories: 
  - High-Availability
tags: [iscsi, scst, pacemaker, drbd, high-availability]
date: 2016-3-12
series: "Highly Available iSCSI ALUA Storage with Pacemaker and DRBD in Dual-Primary mode"
---
{% include toc %}
I already wrote a post on this topic so this is kind of extension or variation of the setup described here [Highly Available iSCSI Storage with SCST, Pacemaker, DRBD and OCFS2]({{ site.baseurl }}{% post_url 2016-3-1-Highly-Available-iSCSI-Storage-with-SCST-Pacemaker-DRBD-and-OCFS2 %}).

The main and most important difference is that thanks to `ALUA` (Asymetric Logical Unit Access) the back-end iSCSI storage can work in `Active/Active` setup thus providing faster fail-over since in this case the resources are not being moved around. Instead, the initiator that now has the paths to the same target on both back-end servers available, can detect when the current active path has failed and quickly switch to the spare one.

The layout described in the above mentioned post is still valid. The only difference is that this time the back-end iSCSI servers are running Ubuntu-14.04.4 LTS, the front-end initiator servers Debian-8.3 Jessie and different subnets are being used.

# iSCSI Target Servers Setup

What was said here in the previous post about iSCSI and the choice of SCST for the task over other solutions goes here as well, especially since we want to use ALUA which is well matured and documented in SCST. The only difference is that I'll be using the `vdisk_blockio` handler for the LUN's instead of `vdisk_fileio` in this case since I want to test its performance too. This is the network configuration on the iSCSI hosts, hpms01:

```
root@hpms01:~# ifconfig
eth0      Link encap:Ethernet  HWaddr 52:54:00:c5:a7:94 
          inet addr:192.168.122.99  Bcast:192.168.122.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:fec5:a794/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:889537 errors:0 dropped:10 overruns:0 frame:0
          TX packets:271329 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:117094884 (117.0 MB)  TX bytes:43494633 (43.4 MB)
 
eth1      Link encap:Ethernet  HWaddr 52:54:00:da:f7:ae 
          inet addr:192.168.152.99  Bcast:192.168.152.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:feda:f7ae/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:512956 errors:0 dropped:10 overruns:0 frame:0
          TX packets:270358 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:60843899 (60.8 MB)  TX bytes:38435981 (38.4 MB)
```

and on hpms02:

```
eth0      Link encap:Ethernet  HWaddr 52:54:00:da:95:17 
          inet addr:192.168.122.98  Bcast:192.168.122.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:feda:9517/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:455133 errors:0 dropped:12 overruns:0 frame:0
          TX packets:697089 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:59913508 (59.9 MB)  TX bytes:93174506 (93.1 MB)
 
eth1      Link encap:Ethernet  HWaddr 52:54:00:6b:56:12 
          inet addr:192.168.152.98  Bcast:192.168.152.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:fe6b:5612/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:296660 errors:0 dropped:12 overruns:0 frame:0
          TX packets:485093 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:32516767 (32.5 MB)  TX bytes:63285013 (63.2 MB)
```

## SCST

I will not go into details this time. Started by installing some prerequisites:

```
# aptitude install fakeroot kernel-wedge build-essential makedumpfile kernel-package libncurses5 libncurses5-dev gcc libncurses5-dev linux-headers-$(uname -r) lsscsi patch subversion lldpad
```

and fetching the SCST source code from SVN as per usual on both nodes:

```
# svn checkout svn://svn.code.sf.net/p/scst/svn/trunk scst-trunk
# cd scst-trunk
# make scst scst_install iscsi iscsi_install scstadm scstadm_install srpt srpt_install
```

I didn't bother re-compiling the kernel to gain some additional benefits in speed this time since in one of my tests on Ubuntu it failed after 2 hours of compiling so decided it's not worth the effort. Plus I'm sure this step is not even needed for the latest kernels.

## DRBD

Nothing new here, will just show the resource configuration file `/etc/drbd.d/vg1.res` for `vg1` after we install the `drbd8-utils` package first of course:

```
resource vg1 {
    startup {
        wfc-timeout 300;
        degr-wfc-timeout 120;
        outdated-wfc-timeout 120;
        become-primary-on both;
    }
    syncer {
        rate 40M;
    }
    disk {
        on-io-error detach;
        fencing resource-only;
        al-extents 3389;
        c-plan-ahead 0;
    }
    handlers {
        fence-peer              "/usr/lib/drbd/crm-fence-peer.sh";
        after-resync-target     "/usr/lib/drbd/crm-unfence-peer.sh";
        outdate-peer            "/usr/lib/heartbeat/drbd-peer-outdater";
    }
    options {
        on-no-data-accessible io-error;
        #on-no-data-accessible suspend-io;
    }
    net {
        allow-two-primaries;
        timeout 60;
        ping-timeout 30;
        ping-int 30;
        cram-hmac-alg "sha1";
        shared-secret "secret";
        max-epoch-size 8192;
        max-buffers 8912;
        sndbuf-size 512k;
        rr-conflict disconnect;
        after-sb-0pri discard-zero-changes;
        after-sb-1pri discard-secondary;
        after-sb-2pri disconnect;
    }
    volume 0 {
       device      /dev/drbd0;
       disk        /dev/sda;
       meta-disk   internal;
    }
    on hpms01 {
       address     192.168.152.99:7788;
    }
    on hpms02 {
       address     192.168.152.98:7788;
     
}
```

where the only noticeable difference is `allow-two-primaries` in the net section, which allows DRBD to become Active on both nodes. The rest is same, we create the meta-data on both nodes and activate the resource:

```
# drbdadm create-md vg1
# drbdadm up vg1
```

and then perform the initial sync on one of them selecting it as `Master`:

```
# drbdadm primary --force vg1
```

When the sync is complete we just promote the other node to primary too:

```
# drbdadm primary vg1
```

after which we have:

```
root@hpms01:~# cat /proc/drbd
version: 8.4.3 (api:1/proto:86-101)
srcversion: 6551AD2C98F533733BE558C
 0: cs:Connected ro:Primary/Primary ds:UpToDate/UpToDate C r-----
    ns:0 nr:0 dw:0 dr:20372 al:0 bm:0 lo:0 pe:0 ua:0 ap:0 ep:1 wo:f oos:0
```

In production environment we also need to adjust fencing mechanism to `fencing resource-and-stonith;` so DRBD passes this task to `Pacemaker` once we have `STONITH` tested and working on the bare metal servers.

## Corosync and Pacemaker

We install needed packages as per usual, this being Ubuntu cloud image I'm using for the VM's I need to install linux-image-extra-virtual package that provides the clustering goodies:

```
# aptitude install linux-image-extra-virtual
# shutdown -r now
```

Then the rest of the software:

```
# aptitude install heartbeat pacemaker corosync fence-agents openais cluster-glue resource-agents dlm lvm2 clvm drbd8-utils sg3-utils
```

Then comes the Corosync configuration file `/etc/corosync/corosync.conf` with double ring setup:

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
    cluster_name: iscsi
 
    # This specifies the mode of redundant ring, which may be none, active, or passive.
    rrp_mode: active
 
    interface {
        ringnumber: 0
        bindnetaddr: 192.168.152.99
        mcastaddr: 226.94.1.1
        mcastport: 5404
    }
    interface {
        ringnumber: 1
        bindnetaddr: 192.168.122.99
        mcastaddr: 226.94.41.1
        mcastport: 5405
    }
    transport: udpu
}
nodelist {
    node {
        ring0_addr: 192.168.152.99
        ring1_addr: 192.168.122.99
        nodeid: 1
    }
    node {
        ring0_addr: 192.168.152.98
        ring1_addr: 192.168.122.99
        nodeid: 2
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
                subsys: subsys: QUORUM
                debug: off
                tags: enter|leave|trace1|trace2|trace3|trace4|trace6
        }
}
```

Starting with Corosync-2.0 new `quorum` section has been introduced. For `2-node` cluster it looks like in the setup above and is very important for proper operation. The option `two_node: 1` tells Corosync this is 2-node cluster and enables the cluster to remain operational when one node powers down or crashes. It implies `expected_votes: 2` to be setup too. The option `wait_for_all: 1` means though that **BOTH** nodes need to be running in order for the cluster to become operational. This is to prevent split-brain situation in case of partitioned cluster on startup.

Then we set Pacemaker parameters for 2 nodes cluster (on one node only):

```
root@hpms02:~# crm configure property stonith-enabled=false
root@hpms02:~# crm configure property no-quorum-policy=ignore
 
root@hpms02:~# crm status
Last updated: Sat Mar  5 11:53:20 2016
Last change: Sat Mar  5 09:53:00 2016 via cibadmin on hpms02
Stack: corosync
Current DC: hpms01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
0 Resources configured
 
Online: [ hpms01 hpms02 ]
```

And finally take care of the auto start:

```
root@hpms02:~# update-rc.d corosync enable
root@hpms01:~# update-rc.d -f pacemaker remove
root@hpms01:~# update-rc.d pacemaker start 50 1 2 3 4 5 . stop 01 0 6 .
root@hpms01:~# update-rc.d pacemaker enable
```

Now we can set DRBD under Pacemaker control (on one of the nodes):

```
root@hpms01:~# crm configure
crm(live)configure# primitive p_drbd_vg1 ocf:linbit:drbd \
    params drbd_resource="vg1" \
    op monitor interval="10" role="Master" \
    op monitor interval="20" role="Slave" \
    op start interval="0" timeout="240" \
    op stop interval="0" timeout="100"
ms ms_drbd p_drbd_vg1 \
    meta master-max="2" master-node-max="1" clone-max="2" clone-node-max="1" notify="true" interleave="true"
crm(live)configure# commit
crm(live)configure# quit
bye
root@hpms01:~#
```

after which the cluster state will be:

```
root@hpms01:~# crm status
Last updated: Wed Mar  9 04:09:38 2016
Last change: Tue Mar  8 12:24:13 2016 via crmd on hpms01
Stack: corosync
Current DC: hpms02 (2) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
10 Resources configured
 
 
Online: [ hpms01 hpms02 ]
 
 Master/Slave Set: ms_drbd [p_drbd_vg1]
     Masters: [ hpms01 hpms02 ]
```

## Fencing

Since our servers are VM's running in `Libvirt/KVM` we can use the `fence_virsh` STONITH device in this case and we enable the STONITH feature in Pacemaker:

```
primitive p_fence_hpms01 stonith:fence_virsh \
   params action="reboot" ipaddr="vm-host" \
          login="root" identity_file="/root/.ssh/id_rsa" \
          port="hpms01"
primitive p_fence_hpms02 stonith:fence_virsh \
   params action="reboot" ipaddr="vm-host" \
          login="root" identity_file="/root/.ssh/id_rsa" \
          port="hpms02"
location l_fence_hpms01 p_fence_hpms01 -inf: hpms01.virtual.local
location l_fence_hpms02 p_fence_hpms02 -inf: hpms02.virtual.local
property stonith-enabled="true"
commit
```

The `location` parameter takes care that the fencing device for hpms01 never ends up on hpms01 and same for hpms02, a node fencing it self does not make any sense. The `port` parameter tells libvirt which VM needs rebooting.

We also need to install the libvirt-bin package to have virsh utility available in the VM's:

```
root@hpms01:~# aptitude install libvirt-bin
```

Then to enable VM fencing and support live VM migration in the hypervizor, we edit the hypervizor host libvirtd config first `/etc/libvirt/libvirtd.conf` as shown bellow:

```
...
listen_tls = 0
listen_tcp = 1
tcp_port = "16509"
auth_tcp = "none"
...
```

and restart:

```
# service libvirt-bin restart
```

After all this has been setup we should be able to access the hypervizor from within our VM's:

```
root@hpms01:~# virsh --connect=qemu+tcp://192.168.1.210/system list --all
 Id    Name                           State
----------------------------------------------------
 15    hpms01                         running
 16    hpms02                         running
 17    proxmox01                      running
 18    proxmox02                      running
```

meaning the fencing should now work. To test it:

```
root@hpms01:~# fence_virsh -a 192.168.1.210 -l root -k ~/.ssh/id_rsa -n hpms02 -o status
Status: ON
 
root@hpms02:~# fence_virsh -a 192.168.1.210 -l root -k ~/.ssh/id_rsa -n hpms01 -o status
Status: ON
```

but we need to add the hpms01 and hpms02 public ssh keys to the hypervisor's `/root/.ssh/authorized_keys` file for password-less login.

Another option is using external/libvirt device in which case we don't need to fiddle with ssh and works over TCP:

```
primitive p_fence_hpms01 stonith:external/libvirt \
  params hostlist="hpms01" \
         hypervisor_uri="qemu+tcp://192.168.1.210/system" \
  op monitor interval="60s"
primitive p_fence_hpms02 stonith:external/libvirt \
  params hostlist="hpms02" \
         hypervisor_uri="qemu+tcp://192.168.1.210/system" \
  op monitor interval="60s"
location l_fence_hpms01 p_fence_hpms01 -inf: hpms01.virtual.local
location l_fence_hpms02 p_fence_hpms02 -inf: hpms02.virtual.local
property stonith-enabled="true"
commit
```

We can confirm it's been started:

```
root@hpms01:~# crm status
Last updated: Fri Mar 18 01:53:38 2016
Last change: Fri Mar 18 01:51:01 2016 via cibadmin on hpms01
Stack: corosync
Current DC: hpms02 (2) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
12 Resources configured
 
Online: [ hpms01 hpms02 ]
 
 Master/Slave Set: ms_drbd [p_drbd_vg1]
     Masters: [ hpms01 hpms02 ]
 Clone Set: cl_lvm [p_lvm_vg1]
     Started: [ hpms01 hpms02 ]
 Master/Slave Set: ms_scst [p_scst]
     Masters: [ hpms02 ]
     Slaves: [ hpms01 ]
 Clone Set: cl_lock [g_lock]
     Started: [ hpms01 hpms02 ]
 p_fence_hpms01    (stonith:external/libvirt):    Started hpms02
 p_fence_hpms02    (stonith:external/libvirt):    Started hpms01
```

In production bare metal server this would be a real remote management dedicated device/card like ILO, iDRAC, IPMI (depending on the server brand) or network managed UPS unit. Example for IPMI LAN device:

```
primitive p_fence_hpms01 stonith:fence_ipmilan \
   pcmk_host_list="pcmk-1" ipaddr="<hpms01_ipmi_ip_address>" \
   action="reboot" login="admin" passwd="secret" delay=15 \
   op monitor interval=60s
primitive p_fence_hpms02 stonith:fence_ipmilan \
   pcmk_host_list="pcmk-2" ipaddr="<hpms02_ipmi_ip_address>" \
   action="reboot" login="admin" passwd="secret" delay=5 \
   op monitor interval=60s
location l_fence_hpms01 p_fence_hpms01 -inf: hpms01.virtual.local
location l_fence_hpms02 p_fence_hpms02 -inf: hpms02.virtual.local
property stonith-enabled="true"
commit
```

The `delay` parameter is needed to avoid dual-fencing in two-node clusters and prevent infinite fencing loop. The node with the `delay="15"` will have a 15 second head-start, so in a network partition triggered fence, the node with the delay should always live and the node without the delay will be immediately fenced.

### Amazon EC2 fencing

This is a special case. If the VM's are running on AWS we need a fencing agent available at [fence_ec2](https://github.com/beekhof/fence_ec2/blob/392a146b232fbf2bf2f75605b1e92baef4be4a01/fence_ec2).

```
# wget -O /usr/sbin/fence_ec2 https://raw.githubusercontent.com/beekhof/fence_ec2/392a146b232fbf2bf2f75605b1e92baef4be4a01/fence_ec2
# chmod 755 /usr/sbin/fence_ec2
```

Then the fence primitive would look something like this:

```
primitive stonith_my-ec2-nodes stonith:fence_ec2 \
   params ec2-home="/root/ec2" action="reboot" \
      pcmk_host_check="static-list" \
      pcmk_host_list="ec2-iscsi-01 ec2-iscsi-02" \
   op monitor interval="600s" timeout="300s" \
   op start start-delay="30s" interval="0"
```

So we need to point the resource to our AWS environment and the API keys to use.

## DLM, CLVM, LVM

What was said in Highly Available iSCSI Storage with Pacemaker and DRBD about DLM problems in Ubuntu applies here too. After sorting out the issues as described in that article we proceed to creating the vg1 volume group, which thanks to CLVM will be clustered,and the Logical Volume (on one node only) which is describe in more details in Highly Available Replicated Storage with Pacemaker and DRBD in Dual-Primary mode. First we set some LVM parameters in `/etc/lvm/lvm.conf`:

```
...
    filter = [ "a|drbd.*|", "r|.*|" ]
    write_cache_state = 0
    locking_type = 3
...
```

to tell LVM to loock for VGs on the DRBD devices only and change the locking type to cluster. Then we can create the volume.

```
root@hpms01:~# pvcreate /dev/drbd0
root@hpms01:~# vgcreate -c y vg1 /dev/drbd0
root@hpms01:~# lvcreate --name lun1 -l 100%vg vg1
```

Although we created the VG on the first node, if we run vgdisplay on the other node we will be able to see the Volume Group there as well. Then we configure the resources in Pacemaker:

```
primitive p_clvm ocf:lvm2:clvmd \
    params daemon_timeout="30" \
    op monitor interval="60" timeout="30" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100"
primitive p_controld ocf:pacemaker:controld \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    params daemon="dlm_controld" \
    meta target-role="Started"
primitive p_lvm_vg1 ocf:heartbeat:LVM \
    params volgrpname="vg1" \
    op start interval="0" timeout="30" \
    op stop interval="0" timeout="30" \
    op monitor interval="0" timeout="30"
clone cl_lock g_lock \
        meta globally-unique="false" interleave="true"
clone cl_lvm p_lvm_vg1 \
        meta interleave="true" target-role="Started" globally-unique="false"
colocation co_drbd_lock inf: cl_lock ms_drbd:Master
colocation co_lock_lvm inf: cl_lvm cl_lock
order o_drbd_lock inf: ms_drbd:promote cl_lock
order o_lock_lvm inf: cl_lock cl_lvm
order o_vg1 inf: ms_drbd:promote cl_lvm:start ms_scst:start
commit
```

after which the state is:

```
root@hpms01:~# crm status
Last updated: Wed Mar  9 04:20:39 2016
Last change: Tue Mar  8 12:24:13 2016 via crmd on hpms01
Stack: corosync
Current DC: hpms02 (2) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
10 Resources configured

Online: [ hpms01 hpms02 ]
 
 Master/Slave Set: ms_drbd [p_drbd_vg1]
     Masters: [ hpms01 hpms02 ]
 Clone Set: cl_lvm [p_lvm_vg1]
     Started: [ hpms01 hpms02 ]
 Clone Set: cl_lock [g_lock]
     Started: [ hpms01 hpms02 ]
```

We created some `colocation` and `order` constraints so the resources start properly and in specific order.

## ALUA

This is the last and crucial step and where the SCST configuration is done. I used this excellent article from [Marc's Adventures in IT Land](http://marcitland.blogspot.com.au/2013/04/building-using-highly-available-esos.html) website as reference for the ALUA setup, which Marc describes in details.

First we load the kernel module prepare the Target on each node:

```
root@hpms01:~# modprobe scst_vdisk
root@hpms01:~# scstadmin -add_target iqn.2016-02.local.virtual:hpms01.vg1 -driver iscsi
 
root@hpms02:~# modprobe scst_vdisk
root@hpms02:~# scstadmin -add_target iqn.2016-02.local.virtual:hpms02.vg1 -driver iscsi
```

Then we configure ALUA, the local and remote Target Group Paths. Instead running all this manually line by line we can put the commands in a file `alua_setup.sh`:

```
scstadmin -add_target iqn.2016-02.local.virtual:hpms02.vg1 -driver iscsi || 1
#scstadmin -set_tgt_attr iqn.2016-02.local.virtual:hpms01.vg1 -driver iscsi -attributes allowed_portal="192.168.122.99 192.168.152.99"
scstadmin -enable_target iqn.2016-02.local.virtual:hpms01.vg1 -driver iscsi
scstadmin -set_drv_attr iscsi -attributes enabled=1
scstadmin -add_dgrp esos
scstadmin -add_tgrp local -dev_group esos
scstadmin -set_tgrp_attr local -dev_group esos -attributes group_id=1
scstadmin -add_tgrp_tgt iqn.2016-02.local.virtual:hpms01.vg1 -dev_group esos -tgt_group local
scstadmin -set_tgt_attr iqn.2016-02.local.virtual:hpms01.vg1 -driver iscsi -attributes rel_tgt_id=1
scstadmin -add_tgrp remote -dev_group esos
scstadmin -set_tgrp_attr remote -dev_group esos -attributes group_id=2
scstadmin -add_tgrp_tgt iqn.2016-02.local.virtual:hpms02.vg1 -dev_group esos -tgt_group remote
scstadmin -set_ttgt_attr iqn.2016-02.local.virtual:hpms02.vg1 -dev_group esos -tgt_group remote -attributes rel_tgt_id=2
scstadmin -open_dev vg1 -handler vdisk_blockio -attributes filename=/dev/vg1/lun1,write_through=1,nv_cache=0
scstadmin -add_lun 0 -driver iscsi -target iqn.2016-02.local.virtual:hpms01.vg1 -device vg1
scstadmin -add_dgrp_dev vg1 -dev_group esos
```

and run it:

```
root@hpms01:~# /bin/bash alua_setup.sh
```

On hpms02 `alua_setup.sh`:

```
scstadmin -add_target iqn.2016-02.local.virtual:hpms02.vg1 -driver iscsi || 1
#scstadmin -set_tgt_attr iqn.2016-02.local.virtual:hpms02.vg1 -driver iscsi -attributes allowed_portal="192.168.122.98 192.168.152.98"
scstadmin -enable_target iqn.2016-02.local.virtual:hpms02.vg1 -driver iscsi
scstadmin -set_drv_attr iscsi -attributes enabled=1
scstadmin -add_dgrp esos
scstadmin -add_tgrp local -dev_group esos
scstadmin -set_tgrp_attr local -dev_group esos -attributes group_id=2
scstadmin -add_tgrp_tgt iqn.2016-02.local.virtual:hpms02.vg1 -dev_group esos -tgt_group local
scstadmin -set_tgt_attr iqn.2016-02.local.virtual:hpms02.vg1 -driver iscsi -attributes rel_tgt_id=2
scstadmin -add_tgrp remote -dev_group esos
scstadmin -set_tgrp_attr remote -dev_group esos -attributes group_id=1
scstadmin -add_tgrp_tgt iqn.2016-02.local.virtual:hpms01.vg1 -dev_group esos -tgt_group remote
scstadmin -set_ttgt_attr iqn.2016-02.local.virtual:hpms01.vg1 -dev_group esos -tgt_group remote -attributes rel_tgt_id=1
scstadmin -open_dev vg1 -handler vdisk_blockio -attributes filename=/dev/vg1/lun1,write_through=1,nv_cache=0
scstadmin -add_lun 0 -driver iscsi -target iqn.2016-02.local.virtual:hpms02.vg1 -device vg1
scstadmin -add_dgrp_dev vg1 -dev_group esos
```

and execute:

```
root@hpms02:~# /bin/bash alua_setup.sh
```

What this does is creates local and remote target groups with id's of 1 and 2 on each node, puts them in a device group called esos and maps the device vg1 to the target LUN. Each target group will be presented as different path to the LUN initiators.

Now the crucial point, integrating this into Pacemaker. I decided to try the SCST ALUA OCF agent from the opened source ESOS (Enterprise Storage OS) project (in lack of any other option really apart from the SCST OCF agent SCSTLunMS that does NOT have required features). I downloaded it from the project GIThub repo:

```
# wget https://raw.githubusercontent.com/astersmith/esos/master/misc/ocf/scst
# mkdir /usr/lib/ocf/resources.d/esos
# mv scst /usr/lib/ocf/resources.d/esos/
# chmod +x /usr/lib/ocf/resources.d/esos/scst
```

However, this agent is prepared for the `ESOS` distribution, that installs on bare metal by the way, so it looks for specific software that we don't need and don't install for our iSCSI usage. Thus it needs some modifications in order to work (fact which I discovered after hours of debugging using ocf-tester utility). So here are the changes `/usr/lib/ocf/resource.d/esos/scst`:

```
...
PATH=$PATH:/usr/local/sbin
...
#MODULES="scst qla2x00tgt iscsi_scst ib_srpt \
#scst_disk scst_vdisk scst_tape scst_changer fcst"
MODULES="scst iscsi_scst scst_disk scst_vdisk"
...
    #if pidof fcoemon > /dev/null 2>&1; then
    #    ocf_log warn "The fcoemon daemon is already running!"
    #else
    #    ocf_run fcoemon -s || exit ${OCF_ERR_GENERIC}
    #fi
...
    #for i in "fcoemon lldpad iscsi-scstd"; do
    for i in "lldpad iscsi-scstd"; do
...
```

So basically, we need to point it to `scstadmin` binary under `/usr/local/sbin` which it was not able to find, and remove `fcoemon` daemon test since we don't need it (Fibre Channel Over Ethernet) and some modules we are not going to be using and have not installed, like `InfiniBand`, `tape` and `disk` charger etc. You can download the file from [here]({{ site.baseurl }}/download/scst).

Now when I ran the OCF test again providing the agent with all needed input parameters:

```
root@hpms01:~/scst-ocf# ocf-tester -v -n ms_scst -o OCF_ROOT=/usr/lib/ocf -o alua=true -o device_group=esos -o local_tgt_grp=local -o remote_tgt_grp=remote -o m_alua_state=active -o s_alua_state=nonoptimized /usr/lib/ocf/resource.d/esos/scst
```

the test passed and the following SCST config file `/etc/scst.conf` was created:

```
# Automatically generated by SCST Configurator v3.1.0-pre1.
 
# Non-key attributes
max_tasklet_cmd 10
setup_id 0x0
suspend 0
threads 2
 
HANDLER vdisk_blockio {
    DEVICE vg1 {
        filename /dev/vg1/lun1
        write_through 1
 
        # Non-key attributes
        block "0 0"
        blocksize 512
        cluster_mode 0
        expl_alua 0
        nv_cache 0
        pr_file_name /var/lib/scst/pr/vg1
        prod_id vg1
        prod_rev_lvl " 320"
        read_only 0
        removable 0
        rotational 1
        size 21470642176
        size_mb 20476
        t10_dev_id 509f7d73-vg1
        t10_vend_id SCST_BIO
        thin_provisioned 0
        threads_num 1
        threads_pool_type per_initiator
        tst 1
        usn 509f7d73
        vend_specific_id 509f7d73-vg1
    }
}
 
TARGET_DRIVER copy_manager {
    # Non-key attributes
    allow_not_connected_copy 0
 
    TARGET copy_manager_tgt {
        # Non-key attributes
        addr_method PERIPHERAL
        black_hole 0
        cpu_mask ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff
        forwarding 0
        io_grouping_type auto
        rel_tgt_id 0
 
        LUN 0 vg1 {
            # Non-key attributes
            read_only 0
        }
    }
}
 
TARGET_DRIVER iscsi {
    enabled 1
 
    TARGET iqn.2016-02.local.virtual:hpms01.vg1 {
        enabled 0
 
        # Non-key attributes
        DataDigest None
        FirstBurstLength 65536
        HeaderDigest None
        ImmediateData Yes
        InitialR2T No
        MaxBurstLength 1048576
        MaxOutstandingR2T 32
        MaxRecvDataSegmentLength 1048576
        MaxSessions 0
        MaxXmitDataSegmentLength 1048576
        NopInInterval 30
        NopInTimeout 30
        QueuedCommands 32
        RDMAExtensions Yes
        RspTimeout 90
        addr_method PERIPHERAL
        black_hole 0
        cpu_mask ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff
        forwarding 0
        io_grouping_type auto
        per_portal_acl 0
        rel_tgt_id 0
 
        LUN 0 vg1 {
            # Non-key attributes
            read_only 0
        }
    }
}
 
DEVICE_GROUP esos {
    DEVICE vg1
 
    TARGET_GROUP local {
        group_id 1
        state nonoptimized
 
        # Non-key attributes
        preferred 0
 
        TARGET iqn.2016-02.local.virtual:hpms01.vg1
    }
 
    TARGET_GROUP remote {
        group_id 2
        state active
 
        # Non-key attributes
        preferred 0
 
        TARGET iqn.2016-02.local.virtual:hpms02.vg1 {
            rel_tgt_id 2
        }
    }
}
```

which matches our ALUA setup.

After that I could finalized the cluster configuration:

```
primitive p_scst ocf:esos:scst \
    params alua="true" device_group="esos" local_tgt_grp="local" remote_tgt_grp="remote" m_alua_state="active" s_alua_state="nonoptimized" \
    op monitor interval="10" role="Master" \
    op monitor interval="20" role="Slave" \
    op start interval="0" timeout="120" \
    op stop interval="0" timeout="60"
ms ms_scst p_scst \
    meta master-max="1" master-node-max="1" clone-max="2" clone-node-max="1" notify="true" interleave="true" target-role="Started"
colocation co_vg1 inf: cl_lvm:Started ms_scst:Started ms_drbd:Master
order o_vg1 inf: ms_drbd:promote cl_lvm:start ms_scst:start
commit
```

So, we create the SCST as Multi State resource passing the ALUA parameters to it. The cluster will put one of the TGPS in `active/active` and the other in `active/nonoptimized` state and we let the cluster decide this since both are replicated via DRBD in `Active/Active` state and the clustered LVM so from a data point of view it doesn't really matter.

After that we have this state in Pacemaker:

```
root@hpms01:~# crm_mon -1 -rfQ
Stack: corosync
Current DC: hpms01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
10 Resources configured
 
Online: [ hpms01 hpms02 ]
 
Full list of resources:
 
 Master/Slave Set: ms_drbd [p_drbd_vg1]
     Masters: [ hpms01 hpms02 ]
 Clone Set: cl_lvm [p_lvm_vg1]
     Started: [ hpms01 hpms02 ]
 Master/Slave Set: ms_scst [p_scst]
     Masters: [ hpms01 ]
     Slaves: [ hpms02 ]
 Clone Set: cl_lock [g_lock]
     Started: [ hpms01 hpms02 ]
 
Migration summary:
* Node hpms02:
* Node hpms01:
```

As we can see all is up and running. For the end, to prevent resource migration due server flapping up and down (bad network lets say) and faster resource failover when a node goes offline:

```
root@hpms02:~# crm configure rsc_defaults resource-stickiness=100
root@hpms02:~# crm configure rsc_defaults migration-threshold=3
```

We can test now the connectivity from one of the clients:

```
root@proxmox01:~# iscsiadm -m discovery -t st -p 192.168.122.98
192.168.122.98:3260,1 iqn.2016-02.local.virtual:hpms02.vg1
192.168.152.98:3260,1 iqn.2016-02.local.virtual:hpms02.vg1
 
root@proxmox01:~# iscsiadm -m discovery -t st -p 192.168.122.99
192.168.122.99:3260,1 iqn.2016-02.local.virtual:hpms01.vg1
192.168.152.99:3260,1 iqn.2016-02.local.virtual:hpms01.vg1
```

As we can see it can discover the targets on both portals, one target per IP the SCST is listening on. For the end, our complete cluster configuration looks like this:

```
root@hpms01:~# crm configure show | cat
node $id="1" hpms01 \
    attributes standby="off"
node $id="2" hpms02
primitive p_clvm ocf:lvm2:clvmd \
    params daemon_timeout="30" \
    op monitor interval="60" timeout="30" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100"
primitive p_controld ocf:pacemaker:controld \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    params daemon="dlm_controld" \
    meta target-role="Started"
primitive p_drbd_vg1 ocf:linbit:drbd \
    params drbd_resource="vg1" \
    op monitor interval="10" role="Master" \
    op monitor interval="20" role="Slave" \
    op start interval="0" timeout="240" \
    op stop interval="0" timeout="100"
primitive p_fence_hpms01 stonith:external/libvirt \
    params hostlist="hpms01" hypervisor_uri="qemu+tcp://192.168.1.210/system" \
    op monitor interval="60s"
primitive p_fence_hpms02 stonith:external/libvirt \
    params hostlist="hpms02" hypervisor_uri="qemu+tcp://192.168.1.210/system" \
    op monitor interval="60s"
primitive p_lvm_vg1 ocf:heartbeat:LVM \
    params volgrpname="vg1" \
    op start interval="0" timeout="30" \
    op stop interval="0" timeout="30" \
    op monitor interval="0" timeout="30"
primitive p_scst ocf:esos:scst \
    params alua="true" device_group="esos" local_tgt_grp="local" remote_tgt_grp="remote" m_alua_state="active" s_alua_state="nonoptimized" \
    op monitor interval="10" role="Master" \
    op monitor interval="20" role="Slave" \
    op start interval="0" timeout="120" \
    op stop interval="0" timeout="60"
group g_lock p_controld p_clvm
ms ms_drbd p_drbd_vg1 \
    meta master-max="2" master-node-max="1" clone-max="2" clone-node-max="1" notify="true" interleave="true"
ms ms_scst p_scst \
    meta master-max="1" master-node-max="1" clone-max="2" clone-node-max="1" notify="true" interleave="true" target-role="Started"
clone cl_lock g_lock \
    meta globally-unique="false" interleave="true"
clone cl_lvm p_lvm_vg1 \
    meta interleave="true" target-role="Started" globally-unique="false"
location l_fence_hpms01 p_fence_hpms01 -inf: hpms01
location l_fence_hpms02 p_fence_hpms02 -inf: hpms02
colocation co_drbd_lock inf: cl_lock ms_drbd:Master
colocation co_lock_lvm inf: cl_lvm cl_lock
colocation co_vg1 inf: cl_lvm:Started ms_scst:Started ms_drbd:Master
order o_drbd_lock inf: ms_drbd:promote cl_lock
order o_lock_lvm inf: cl_lock cl_lvm
order o_vg1 inf: ms_drbd:promote cl_lvm:start ms_scst:start
property $id="cib-bootstrap-options" \
    dc-version="1.1.10-42f2063" \
    cluster-infrastructure="corosync" \
    stonith-enabled="true" \
    no-quorum-policy="ignore" \
    last-lrm-refresh="1458176609"
rsc_defaults $id="rsc-options" \
    resource-stickiness="100" \
    migration-threshold="3"
```

{% include series.html %}