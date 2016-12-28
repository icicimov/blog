---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Highly Available iSCSI Storage with SCST, Pacemaker, DRBD and OCFS2 - Part1'
categories: 
  - High-Availability
tags: [iscsi, scst, pacemaker, drbd, ocfs2, high-availability]
date: 2016-3-1
series: "Highly Available iSCSI Storage with SCST, Pacemaker, DRBD and OCFS2"
---
{% include toc %}
[SCST](http://scst.sourceforge.net/) the generic SCSI target subsystem for Linux, allows creation of sophisticated storage devices from any Linux box. Those devices can provide advanced functionality, like replication, thin provisioning, deduplication, high availability, automatic backup, etc. SCST devices can use any link which supports SCSI-style data exchange: iSCSI, Fibre Channel, FCoE, SAS, InfiniBand (SRP), Wide (parallel) SCSI, etc.

What we are going to setup is shown in the ASCII chart below. The storage stack will provide `iSCSI` service to the clients by exporting `LUN's` via single target. The clients (iSCSI initiators) will access the LUN's via multipathing for high-availability and keep the files in sync via `OCFS2` clustered file system. On the server side, DRBD is tasked to sync the block storage on both servers and provide fail-over capacity. Both clusters will be managed by `Pacemaker` cluster stack.

```
                                                                        192.168.0.0/24            +----------+
--------------------------------------------------------------------------------------------------|  router  |-----------
          drbd01                                 drbd02                                |          +----------+
+----------+  +----------+             +----------+  +----------+                      |
|  Service |  |  Service |             |  Service |  |  Service |                      |
+----------+  +----------+             +----------+  +----------+                      |
     ||            ||                       ||            ||                           |
+------------------------+             +------------------------+                      |
|         ocfs2          |<~~~~~~~~~~~>|          ocfs2         |                      |
+------------------------+             +------------------------+                      |
|       multipath        |             |       multipath        |                      |
+------------------------+             +------------------------+                      |
|        sdc,sdd         |             |        sdc,sdd         |                      |
+------------------------+             +------------------------+                      |
|         iscsi          |             |         iscsi          |                      |
+------------------------+             +------------------------+                      |
  |   |   |                               |   |   |                  10.10.1.0/24      |
----------+---------------------------------------+-------------------------------     |
  |   |                                   |   |                      10.20.1.0/24      |
------+--------------+------------------------+--------------+--------------------     |
  |                  |                    |                  |                         |
--+-------------+-------------------------+-------------+-------------------------------
                |    |                                  |    |
+------------------------+             +------------------------+
|         iscsi          |             |          iscsi         |
+------------------------+             +------------------------+
|        lv_vol          |             |         lv_vol         |
+------------------------+             +------------------------+
|   volume group vg1     |             |    volume group vg1    |
+------------------------+             +------------------------+
|     physical volume    |             |     physical volume    |
+------------------------+             +------------------------+
|        drbd r0         |<~~~~~~~~~~~>|        drbd r0         |
+------------------------+             +------------------------+
|          sdb           |             |          sdb           |
+------------------------+             +------------------------+
        centos01                               centos02
```

Each client server (drbd01 and drbd02) has three interfaces each connected to three separate networks of which only the external one, `192.168.0.0/24` is routed. The other two, `10.10.1.0/24` and  `10.20.1.0/24`, are private networks dedicated to the DRBD and iSCSI traffic respectively. All 4 servers are connected to the `10.20.1.0/24` network ie the storage network.

Here is the hosts configuration in the `/etc/hosts` file on all 4 nodes:

```
...
10.10.1.17      drbd01.virtual.local    drbd01
10.10.1.19      drbd02.virtual.local    drbd02
10.20.1.17      centos01.virtual.local  centos01
10.20.1.11      centos02.virtual.local  centos02
```
 
# iSCSI Target Servers Setup

The servers will be running CentOS-6.7 since the iSCSI and Pacemaker are generally better supported on RHEL/CentOS distributions. There are several iSCSI providers ie IET, STGT, LIO and SCST and I've chosen SCST for it's stability, speed and array of features that others don't provide ie ALUA. Unfortunately it has not been merged in the upstream Linux kernel, LIO got that privilege in the latest kernels, so it needs installation from source and kernel patching for best results. Helper scripts are provided in the source to make this otherwise tedious task very simple.

The `sdb` virtual disk attached to the server VM's and used as backing device for the iSCSI volumes are created with `write-through` cache. This, or no cache at all, is the best choice when data security is of highest importance on expanse of speed. We'll be using the `vdisk_fileio` mode in SCST devices since it performs better in virtual environments over `vdisk_blockio` although we are still presenting the LUN's as block devices to the initiators letting them to format the drive.

## SCST

We start by installing some needed software (on both nodes, centos01 and centos02:

```
[root@centos01 ~]# yum install svn asciidoc newt-devel xmlto rpm-build redhat-rpm-config gcc make \
                       patchutils elfutils-libelf-devel elfutils-devel zlib-devel binutils-devel \
                       python-devel audit-libs-devel bison hmaccalc perl-ExtUtils-Embed rng-tools \
                       ncurses-devel kernel-devel
```

We need `rngd` since we are running in VM's and have not enough entropy for generating Corosync authentication key for example. Edit the `/etc/sysconfig/rngd` config file:

```
...
EXTRAOPTIONS="-r /dev/urandom"
```

start it up:

```
[root@centos01 ~]# service rngd start
[root@centos01 ~]# chkconfig rngd on
```

Fetch the SCST source from trunk:

```
[root@centos01 ~]# svn checkout svn://svn.code.sf.net/p/scst/svn/trunk scst-trunk
[root@centos01 ~]# cd scst-trunk
```

Then we run:

```
[root@centos01 scst-trunk]# ./scripts/rebuild-rhel-kernel-rpm
```

This script will build for us a version of the RHEL/CentOS/SL kernel we are running with the SCST patches applied on top. Then we install the new kernel and boot into it:

```
[root@centos01 scst-trunk]# yum -iVh ../*.rmp
[root@centos01 scst-trunk]# shutdown -r now
```

Last step is to compile and install the scst services and modules we need:

```
[root@centos01 scst-trunk]# make scst scst_install
[root@centos01 scst-trunk]# make iscsi iscsi_install
[root@centos01 scst-trunk]# make scstadm scstadm_install
```

Now we check if everything is working properly. We need to set minimum config file to start with:

```
[root@centos01 ~]# vi /etc/scst.conf
TARGET_DRIVER iscsi {
    enabled 1
}
```

and start the service:

```
[root@centos01 ~]# service scst start
Loading and configuring SCST                               [  OK  ]
```

and check if all has been started and loaded properly:

```
[root@centos01 ~]# lsmod | grep scst
isert_scst             73646  3
iscsi_scst            191131  4 isert_scst
rdma_cm                36354  1 isert_scst
ib_core                81507  6 isert_scst,rdma_cm,ib_cm,iw_cm,ib_sa,ib_mad
scst                 2117799  2 isert_scst,iscsi_scst
dlm                   148135  1 scst
libcrc32c               1246  3 iscsi_scst,drbd,sctp
crc_t10dif              1209  2 scst,sd_mod
 
[root@centos01 ~]# ps aux | grep scst
root      3008  0.0  0.0      0     0 ?        S    16:28   0:00 [scst_release_ac]
root      3009  0.0  0.0      0     0 ?        S    16:28   0:00 [scst_release_ac]
root      3010  0.0  0.0      0     0 ?        S    16:28   0:00 [scst_release_ac]
root      3011  0.0  0.0      0     0 ?        S    16:28   0:00 [scst_release_ac]
root      3012  0.0  0.0      0     0 ?        S<   16:28   0:00 [scst_uid]
root      3013  0.0  0.0      0     0 ?        S    16:28   0:00 [scstd0]
root      3014  0.0  0.0      0     0 ?        S    16:28   0:00 [scstd1]
root      3015  0.0  0.0      0     0 ?        S    16:28   0:00 [scstd2]
root      3016  0.0  0.0      0     0 ?        S    16:28   0:00 [scstd3]
root      3017  0.0  0.0      0     0 ?        S<   16:28   0:00 [scst_initd]
root      3019  0.0  0.0      0     0 ?        S<   16:28   0:00 [scst_mgmtd]
root      3054  0.0  0.0   4152   648 ?        Ss   16:28   0:00 /usr/local/sbin/iscsi-scstd
```

All looks good so the SCST part is finished. At the end we check if SCST service has been added to auto-start and if yes we remove it since we want to be under Pacemaker control:

```
[root@centos01 scst-trunk]# chkconfig --list scst
[root@centos01 scst-trunk]# chkconfig scst off
[root@centos01 scst-trunk]# chkconfig --list scst
scst            0:off   1:off   2:off   3:off   4:off   5:off   6:off
```

## DRBD

We start by installing DRBD-8.4 on both servers:

```
# yum install -y drbd84-utils kmod-drbd84
```

Then we create our DRBD resource that will provide the backing device for the volume group and logical volume we want to create. Create new file `/etc/drbd.d/vg1.res`:

```
resource vg1 {
    startup {
        wfc-timeout 30;
        degr-wfc-timeout 20;
        outdated-wfc-timeout 10;
    }
    syncer {
        rate 40M;
    }
    disk {
        on-io-error detach;
        fencing resource-and-stonith;
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
        timeout 60;
        ping-timeout 30;
        ping-int 30;
        cram-hmac-alg "sha1";
        shared-secret "secret";
        max-epoch-size 8192;
        max-buffers 8912;
        after-sb-0pri discard-zero-changes;
        after-sb-1pri discard-secondary;
        after-sb-2pri disconnect;
    }
    volume 0 {
       device      /dev/drbd0;
       disk        /dev/sdb;
       meta-disk   internal;
    }
    on centos01 {
       address     10.20.1.17:7788;
    }
    on centos02 {
       address     10.20.1.11:7788;
     
}
```

Then we start drbd on both nodes:

```
# modprobe drbd
```

create the meta data:

```
# drbdadm create-md vg1
# drbdadm up vg1
```

and then on one server only we promote the resource to primary state:

```
[root@centos01 ~] drbdadm primary --force vg1
```

The initial sync of the block device will start and when finished we have:

```
[root@centos01 ~]# cat /proc/drbd
version: 8.4.7-1 (api:1/proto:86-101)
GIT-hash: 3a6a769340ef93b1ba2792c6461250790795db49 build by mockbuild@Build64R6, 2016-01-12 13:27:11
 0: cs:Connected ro:Secondary/Primary ds:UpToDate/UpToDate C r-----
    ns:0 nr:25992756 dw:25992756 dr:0 al:0 bm:0 lo:0 pe:0 ua:0 ap:0 ep:1 wo:f oos:0
```

All is `UpToDate` and we are done with DRBD, we can switch it off and disable it on both nodes since it will be managed by Pacemaker:

```
# service drbd stop
# chkconfig drbd off
```

We need to leave this though for after we execute the next step where we create the logical volume.

## LVM

We use this layer so we can easily extend our storage. We just add new volume to the DRBD resource and extend the PV, VG and LV that we create on top of it. On both nodes:

```
# yum install -y lvm2
```

then we tell LVM to look for VG's on our system and DRBD device only by setting the filter option. We also make sure the locking is set properly, the file is `/etc/lvm/lvm.conf`:

```
...
    filter = [ "a|/dev/sda*|", "a|/dev/drbd*|", "r|.*|" ]
    write_cache_state = 0
    volume_list = [ "vg_centos", "vg1", "vg2" ]
...
```

and remove some possibly stale cache file:

```
# rm -f /etc/lvm/cache/.cache
```

then we can create our VG and LV (on one node only since DRBD will replicate this for us):

```
[root@centos01 ~]# vgcreate vg1 /dev/drbd0
[root@centos01 ~]# lvcreate --name lun1 -l 100%vg vg1
[root@centos01 ~]# vgchange -aey vg1
```

We are done with this part.


## Corosync and Pacemaker

Corosync is the cluster messaging layer and provides communication for the Pacemaker cluster nodes. On both nodes:

```
# yum install -y pacemaker corosync ipmitool openais cluster-glue fence-agents scsi-target-utils OpenIPMI OpenIPMI-libs freeipmi freeipmi-bmc-watchdog freeipmi-ipmidetectd
```

then we add the HA-Cluster repository to install `crmsh` from, create `/etc/yum.repos.d/ha-clustering.repo` file:

```
[haclustering]
name=HA Clustering
baseurl=http://download.opensuse.org/repositories/network:/ha-clustering:/Stable/CentOS_CentOS-6/
enabled=0
gpgcheck=0
```

and run:

```
# yum --enablerepo haclustering install -y crmsh
```

Now we setup Corosync with dual ring and active mode in the `/etc/corosync/corosync.conf` file:

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
 
    # This specifies the mode of redundant ring, which may be none, active, or passive.
     rrp_mode: active
 
     interface {
        member {
            memberaddr: 10.20.1.17
        }
        member {
            memberaddr: 10.20.1.11
        }
        ringnumber: 0
        bindnetaddr: 10.20.1.11
        mcastaddr: 226.94.1.1
        mcastport: 5404
    }
    interface {
        member {
            memberaddr: 192.168.0.178
        }
        member {
            memberaddr: 192.168.0.179
        }
        ringnumber: 1
        bindnetaddr: 192.168.0.179
        mcastaddr: 226.94.41.1
        mcastport: 5405
   }
   transport: udpu
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

We start the service on both nodes and check:

```
# service corosync start
 
# corosync-cfgtool -s
Printing ring status.
Local node ID 184620042
RING ID 0
    id    = 10.20.1.11
    status    = ring 0 active with no faults
RING ID 1
    id    = 192.168.0.179
    status    = ring 1 active with no faults
```

All looks good. We set Corosync to auto-start and we are done:

```
# chkconfig corosync on
# chkconfig --list corosync
corosync           0:off    1:off    2:on    3:on    4:on    5:on    6:off
```

Now we start Pacemaker on both nodes and check its status.

```
[root@centos01 ~]# service pacemaker start
 
[root@centos01 ~]# crm status
Last updated: Fri Feb 26 12:49:06 2016
Last change: Fri Feb 26 12:48:47 2016
Stack: classic openais (with plugin)
Current DC: centos01 - partition with quorum
Version: 1.1.11-97629de
2 Nodes configured, 2 expected votes
12 Resources configured
 
Online: [ centos01 centos02 ]
```

All looks good so we enable it to auto-start on both nodes:

```
# chkconfig pacemaker on
# chkconfig --list pacemaker
pacemaker          0:off    1:off    2:on    3:on    4:on    5:on    6:off
```

Now comes the main configuration. We need to setup all the resources we have created till now in Pacemaker. I got the OCF agents `SCSTLun` and `SCSTTarget` from [scst-ocf](https://github.com/rbicelli/scst-ocf) and placed them under new directory I created `/usr/lib/ocf/resources.d/scst/`, since I could see they were providing more functionality then the ones bundled in the SCST svn source.

When I was done, the full config looked like this:

```
[root@centos01 ~]# crm configure show
node centos01
node centos02 \
        attributes standby=off
primitive p_drbd_vg1 ocf:linbit:drbd \
        params drbd_resource=vg1 \
        op start interval=0 timeout=240 \
        op promote interval=0 timeout=90 \
        op demote interval=0 timeout=90 \
        op notify interval=0 timeout=90 \
        op stop interval=0 timeout=100 \
        op monitor interval=30 timeout=20 role=Slave \
        op monitor interval=10 timeout=20 role=Master
primitive p_email_admin MailTo \
        params email="igorc@encompasscorporation.com" subject="Cluster Failover"
primitive p_ip_vg1 IPaddr2 \
        params ip=192.168.0.180 cidr_netmask=24 nic=eth1 \
        op monitor interval=10s
primitive p_ip_vg1_2 IPaddr2 \
        params ip=10.20.1.180 cidr_netmask=24 nic=eth2 \
        op monitor interval=10s
primitive p_lu_vg1_lun1 ocf:scst:SCSTLun \
        params iscsi_enable=true target_iqn="iqn.2016-02.local.virtual:virtual.vg1" \
               iscsi_lun=0 path="/dev/vg1/lun1" handler=vdisk_fileio device_name=VDISK-LUN01 \
        additional_parameters="nv_cache=1 write_through=0 thin_provisioned=0 threads_num=4" wait_timeout=60 \
        op monitor interval=10s timeout=120s
primitive p_lvm_vg1 LVM \
        params volgrpname=vg1 \
        op monitor interval=60 timeout=30 \
        op start timeout=30 interval=0 \
        op stop timeout=30 interval=0 \
        meta target-role=Started
primitive p_portblock_vg1 portblock \
        params ip=192.168.0.180 portno=3260 protocol=tcp action=block \
        op monitor timeout=10s interval=10s depth=0
primitive p_portblock_vg1_2 portblock \
        params ip=10.20.1.180 portno=3260 protocol=tcp action=block \
        op monitor timeout=10s interval=10s depth=0
primitive p_portblock_vg1_2_unblock portblock \
        params ip=10.20.1.180 portno=3260 protocol=tcp action=unblock \
        op monitor timeout=10s interval=10s
primitive p_portblock_vg1_unblock portblock \
        params ip=192.168.0.180 portno=3260 protocol=tcp action=unblock \
        op monitor timeout=10s interval=10s
primitive p_target_vg1 ocf:scst:SCSTTarget \
        params iscsi_enable=true iqn="iqn.2016-02.local.virtual:virtual.vg1" \
               portals="192.168.0.180 10.20.1.180" wait_timeout=60 additional_parameters="DefaultTime2Retain=60 DefaultTime2Wait=5" \
        op monitor interval=10s timeout=120s \
        meta target-role=Started
group g_vg1 p_lvm_vg1 p_target_vg1 p_lu_vg1_lun1 p_ip_vg1 p_ip_vg1_2 p_portblock_vg1 p_portblock_vg1_unblock \
            p_portblock_vg1_2 p_portblock_vg1_2_unblock p_email_admin
ms ms_drbd_vg1 p_drbd_vg1 \
        meta master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 resource-stickiness=100 interleave=true notify=true target-role=Started
colocation c_vg1_on_drbd +inf: g_vg1 ms_drbd_vg1:Master
order o_drbd_before_vg1 +inf: ms_drbd_vg1:promote g_vg1:start
order o_lun_before_ip +inf: p_lu_vg1_lun1 p_ip_vg1
order o_lvm_before_lun +inf: p_lvm_vg1 p_lu_vg1_lun1
property cib-bootstrap-options: \
        dc-version=1.1.11-97629de \
        cluster-infrastructure="classic openais (with plugin)" \
        expected-quorum-votes=2 \
        stonith-enabled=false \
        no-quorum-policy=ignore \
        last-lrm-refresh=1456448175
```

We can play with the SCST parameters to find the optimal setup for best speed, for example we can set `threads_num=4`  for the storage device on the fly, since we have 4 x CPUs, without stopping SCST and test its impact:

```
[root@centos01 ~]# scstadmin -set_dev_attr VDISK-LUN01 -attributes threads_num=4
```

The whole cluster in running state:

```
[root@centos01 ~]# crm status
Last updated: Fri Feb 26 12:49:06 2016
Last change: Fri Feb 26 12:48:47 2016
Stack: classic openais (with plugin)
Current DC: centos01 - partition with quorum
Version: 1.1.11-97629de
2 Nodes configured, 2 expected votes
12 Resources configured
 
Online: [ centos01 centos02 ]
 
Full list of resources:
 
 Master/Slave Set: ms_drbd_vg1 [p_drbd_vg1]
     Masters: [ centos02 ]
     Slaves: [ centos01 ]
 Resource Group: g_vg1
     p_lvm_vg1    (ocf::heartbeat:LVM):    Started centos02
     p_target_vg1    (ocf::scst:SCSTTarget):    Started centos02
     p_lu_vg1_lun1    (ocf::scst:SCSTLun):    Started centos02
     p_ip_vg1    (ocf::heartbeat:IPaddr2):    Started centos02
     p_ip_vg1_2    (ocf::heartbeat:IPaddr2):    Started centos02
     p_portblock_vg1    (ocf::heartbeat:portblock):    Started centos02
     p_portblock_vg1_unblock    (ocf::heartbeat:portblock):    Started centos02
     p_portblock_vg1_2    (ocf::heartbeat:portblock):    Started centos02
     p_portblock_vg1_2_unblock    (ocf::heartbeat:portblock):    Started centos02
     p_email_admin    (ocf::heartbeat:MailTo):    Started centos02
```

> **NOTE**: In production, usage of Fencing ie STONITH in Pacemaker is a MUST. We don't use it here since our setup is running on VM's but no production cluster should be running without it.

We can see that all resources have been started on the second node centos02 in this case. In short the DRBD backed volume is presented as LUN via SCST target and available via two VIP's managed by Pacemaker, one per each of the public 192.168.0.0/24 and the storage 10.20.1.0/24 network. From the Ubuntu client nodes this will be seen as:

```
root@drbd01:~# iscsiadm -m discovery -I default -t st -p 192.168.0.180
192.168.0.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
10.20.1.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
 
root@drbd02:~# iscsiadm -m discovery -I default -t st -p 192.168.0.180
192.168.0.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
10.20.1.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
```

Then I logged in as well:

```
{% raw %}
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 -p 192.168.0.180 --login
Logging in to [iface: default, target: iqn.2016-02.local.virtual:virtual.vg1, portal: 192.168.0.180,3260] (multiple)
Login to [iface: default, target: iqn.2016-02.local.virtual:virtual.vg1, portal: 192.168.0.180,3260] successful.
{% endraw %}
```

And could confirm new block device was created on the client:

```
root@drbd01:~# fdisk -l /dev/sdc
 
Disk /dev/sdc: 21.5 GB, 21470642176 bytes
64 heads, 32 sectors/track, 20476 cylinders, total 41934848 sectors
Units = sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 524288 bytes
Disk identifier: 0x00000000
Disk /dev/sdc doesn't contain a valid partition table
```

which is our 20GB LUN from the target. We can now format and mount `/dev/sdc` as we would do with any block storage device.

{% include series.html %}