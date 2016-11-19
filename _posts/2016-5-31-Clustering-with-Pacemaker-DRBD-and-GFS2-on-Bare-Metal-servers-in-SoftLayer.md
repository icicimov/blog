---
type: posts
header:
  teaser: 'cluster.jpg'
title: 'Clustering with Pacemaker, DRBD and GFS2 on Bare-Metal servers in SoftLayer'
categories: 
  - High-Availability
tags: [cluster, high-availability, pacemaker, drbd, gfs2]
date: 2016-5-31
---
{% include toc %}
[SoftLayer](http://www.softlayer.com/) is IBM company providing cloud and Bare-Metal hosting services. We are going to setup a cluster of Pacemaker, DRBD and GFS2 on couple of Bare-Metal servers to host our Encompass services. This will provide high availability of the shared storage for our applications.

The services are running on two 2U Supermicro 2 x Hexa Core (6 cores per cpu = 24 cpu's in total due to hyper threading) Intel Xeon 2650 bare-metal servers with 64GB of RAM and Ubuntu-14.04.4 server minimal install for OS and 4 x 1TB hard drives. The root file system is on one 1TB SATA drive and the other 3 x 1TB are in hardware RAID5 array via LSI controller, to be used for the shared storage.

The shared file system resides on the 2TB RAID5 SATA array and is kept in sync via DRBD (on top of LVM for easy extension) block level replication and GFS2 clustered file system. The DRBD and GFS2 are managed as resources by Pacemaker. The below ASCII chart might describe this layout better:

```
+----------+  +----------+             +----------+  +----------+
|  Service |  |  Service |             |  Service |  |  Service |
+----------+  +----------+             +----------+  +----------+
     ||            ||                       ||            ||
+------------------------+  cluster FS +------------------------+
|          gfs2          |<~~~~~~~~~~~>|          gfs2          |
+------------------------+ replication +------------------------+
|        drbd r0         |<~~~~~~~~~~~>|         drbd r0        |
+------------------------+             +------------------------+
|        lv_vol          |             |         lv_vol         |
+------------------------+             +------------------------+
|   volume group vg1     |             |    volume group vg1    |
+------------------------+             +------------------------+
|     physical volume    |             |     physical volume    |
+------------------------+             +------------------------+
|          sdb1          |             |          sdb1          |
+------------------------+             +------------------------+
         server01                               server02
```

SoftLayer gives you one public and one private VLAN to connect your server for which you can opt for 0.1, 1 or 10 Gbps throughput. Each server has bond of 2 interfaces connected to each VLAN for HA and fail-over plus one IPMI/KVM BCM interface connected to the private VLAN.

# Disk Setup

We have 3 x 1TB SATA3 disks in RAID5 =~ 2TB usable space. I have created the following partitions on the RAID5 block device `/dev/sdb` (using GPT partition table since it's 2TB disk):

```
root@server01:~# gdisk -l /dev/sdb
GPT fdisk (gdisk) version 0.8.8
Partition table scan:
  MBR: protective
  BSD: not present
  APM: not present
  GPT: present
 
Found valid GPT with protective MBR; using GPT.
Disk /dev/sdb: 3904897024 sectors, 1.8 TiB
Logical sector size: 512 bytes
Disk identifier (GUID): 18E19822-8B06-460E-B2C4-A98E63C284FD
Partition table holds up to 128 entries
First usable sector is 34, last usable sector is 3904896990
Partitions will be aligned on 2048-sector boundaries
Total free space is 2604662717 sectors (1.2 TiB)
 
Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048       524290047   250.0 GiB   8300  Linux filesystem
   2       524290048      1048578047   250.0 GiB   8300  Linux filesystem
   3      1048578048      1300236287   120.0 GiB   8300  Linux filesystem
```

For the shared file system I used the first partition to create LVM of size 200GB leaving around 20% for snapshots:

```
[ALL]:~# pvcreate /dev/sdb1
  Physical volume "/dev/sdb1" successfully created
 
[ALL]:~# vgcreate -A y vg_drbd0 /dev/sdb1
  Volume group "vg_drbd0" successfully created
 
[ALL]:~# lvcreate --name lv_drbd0 -L 200G vg_drbd0
  Logical volume "lv_drbd0" created
```

At the end we need to tell LVM where to look for logical volumes and which devices to skip:

```
[ALL]:~# vi /etc/lvm/lvm.conf
...
    filter = [ "r|^/dev/drbd.*$|", "a|^/dev/sda.*$|", "a|^/dev/sdb.*$|", "r/.*/" ]
    write_cache_state = 1
...
```

and we also turn off the LVM write cache to avoid another caching level. Then we need to update the `ramdisk` in order to synchronize the initramfs's copy of `lvm.conf` with the main system one:

```
[ALL]:~# # update-initramfs -u
update-initramfs: Generating /boot/initrd.img-3.13.0-86-generic
```

otherwise devices might go missing upon reboot.

# Services Setup

We start by updating the kernel and the packages and installing the needed software:

```
[ALL]:~# aptitude update && aptitude safe-upgrade -y && shutdown -r now
[ALL]:~# aptitude install -y heartbeat pacemaker corosync fence-agents openais cluster-glue resource-agents xfsprogs lvm2 gfs2-utils dlm
[ALL]:~# aptitude install -y linux-headers build-essential module-assistant flex debconf-utils docbook-xml docbook-xsl dpatch xsltproc autoconf2.13 autoconf debhelper git
```

I also setup DNS names for the private VLAN ip's in the `/etc/hosts` file:

```
...
10.10.10.91    sl01.private
10.10.10.26    sl02.private
```

Now we can go on and configure our services.

## Clustering Components

For this to work properly we must set passwordless access for the root user on the private VLAN. We generate SSH keys on both servers:

```
[ALL]:~# ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ''
```

and copy-paste the public key into the others server `/root/.ssh/authorized_keys` file or use `ssh-copy-id` for that purpose.

### Corosync

We start by generating private key on one of the servers and copying it over to the other:

```
root@server01:~# corosync-keygen -l
root@server01:~# scp /etc/corosync/authkey server02.private:/etc/corosync/authkey
```

In this way, for added security, only a server that has this key can join the cluster communication. Next is the config file `/etc/corosync/corosync.conf`:

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
 
    # Limit generated nodeids to 31-bits (positive signed integers)
    clear_node_high_bit: yes
 
    # Disable encryption
    secauth: off
 
    # How many threads to use for encryption/decryption
    threads: 0
 
    # Optionally assign a fixed node id (integer)
    # nodeid: 1234
 
    # CLuster name, needed for GFS2 and DLM or DLM wouldn't start
    cluster_name: slcluster
 
    # This specifies the mode of redundant ring, which may be none, active, or passive.
    rrp_mode: none
 
    interface {
        # The following values need to be set based on your environment
        ringnumber: 0
        bindnetaddr: 10.10.10.91
        mcastaddr: 226.94.1.1
        mcastport: 5405
    }
    transport: udpu
}
 
nodelist {
    node {
        ring0_addr: 10.10.10.91
        nodeid: 1
    }
    node {
        ring0_addr: 10.10.10.26
        nodeid: 2
    }
}
 
amf {
    mode: disabled
}
 
quorum {
    # Quorum for the Pacemaker Cluster Resource Manager
    provider: corosync_votequorum
    expected_votes: 1
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
                subsys: AMF
                debug: off
                tags: enter|leave|trace1|trace2|trace3|trace4|trace6
        }
}
```

On the other node we replace `bindnetaddr` to read `bindnetaddr: 10.10.10.26`. Then we enable the service on both servers in `/etc/default/corosync` file:

```
# start corosync at boot [yes|no]
START=yes
```

and start it up:

```
[ALL]:~# service corosync start
```

Confirm all is ok:

```
root@server02:~# corosync-cfgtool -s
Printing ring status.
Local node ID 2
RING ID 0
    id    = 10.10.10.26
    status    = ring 0 active with no faults
 
root@server02:~# corosync-quorumtool
Quorum information
------------------
Date:             Mon May 23 01:46:03 2016
Quorum provider:  corosync_votequorum
Nodes:            2
Node ID:          2
Ring ID:          24
Quorate:          Yes
Votequorum information
----------------------
Expected votes:   2
Highest expected: 2
Total votes:      2
Quorum:           2 
Flags:            Quorate
Membership information
----------------------
    Nodeid      Votes Name
         2          1 10.10.10.26 (local)
         1          1 10.10.10.91
```

For the end, we make sure to open `UDP port 5405` in the firewall on the private VLAN interface and make sure the service is enabled on startup:

```
[ALL]# update-rc.d corosync enable
```

### Pacemaker

Since we already installed it all we need to do is start it up:

```
[ALL]:~# service pacemaker start
```

then set "no-quorum-policy` to `ignore` since this is a 2-node cluster and we want to continue running when one of them crushes (meaning we've lost quorum) and disable fencing for now.:

```
root@server01:~# crm configure property stonith-enabled=false
root@server01:~# crm configure property no-quorum-policy=ignore
```

and then we should see both nodes online if we check the status:

```
root@server01:~# crm status   
Last updated: Mon May 23 01:42:02 2016
Last change: Mon May 23 01:08:41 2016 via cibadmin on server02
Stack: corosync
Current DC: server01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
2 Resources configured
 
Online: [ server01 server02 ]
``` 

Last, we enable the Pacemaker service on startup and make sure it starts after Corosync:

```
[ALL]# update-rc.d -f pacemaker remove
[ALL]# update-rc.d pacemaker start 50 1 2 3 4 5 . stop 01 0 6 .
[ALL]# update-rc.d pacemaker enable
```

### Fencing

To make sure the cluster functions properly we need to configure some kind of fencing. This is to prevent `split-brain` situation in case of partitioned cluster. In Pacemaker terms this is called STONITH (Shoot The Other Node In The Head) and we'll be using the `IPMI-over-lan` device we saw configured above. On one node only we do:

```
root@server01:~# crm configure
crm(live)configure# primitive p_fence_server01 stonith:fence_ipmilan \
   pcmk_host_list="server01" ipaddr="10.10.10.52" \
   action="reboot" login="<my-admin-user>" passwd="<my-admin-password>" delay=15 \
   op monitor interval="60s"
crm(live)configure# primitive p_fence_server02 stonith:fence_ipmilan \
   params pcmk_host_list="server02" ipaddr="10.10.10.71" \
   action="reboot" login="<my-admin-user>" passwd="<my-admin-password>" delay=5 \
   op monitor interval=60s
crm(live)configure# location l_fence_server01 p_fence_server01 -inf: server01
crm(live)configure# location l_fence_server02 p_fence_server02 -inf: server02
crm(live)configure# property stonith-enabled="true"
crm(live)configure# commit
crm(live)configure# exit
root@server01:~#
```

Now if we check the cluster state we can see our new fencing resources configured:

```
root@server01:~# crm status   
Last updated: Mon May 23 01:42:02 2016
Last change: Mon May 23 01:08:41 2016 via cibadmin on server02
Stack: corosync
Current DC: server01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
2 Resources configured
 
Online: [ server01 server02 ]
 
 p_fence_server01    (stonith:fence_ipmilan):    Started server02
 p_fence_server02    (stonith:fence_ipmilan):    Started server01
```

## DRBD

I built DRBD kernel module and the utilities for the current running kernel `3.13.0-86-generic` from the current git repository. For DRBD utils:

```
[ALL]:~# git clone --recursive git://git.drbd.org/drbd-utils.git
[ALL]:~# cd drbd-utils/
[ALL]:~/drbd-utils# ./autogen.sh
[ALL]:~/drbd-utils# ./configure --prefix=/usr --localstatedir=/var --sysconfdir=/etc \
                          --with-pacemaker=yes --with-heartbeat=yes --with-rgmanager=yes \
                          --with-xen=yes --with-bashcompletion=yes
[ALL]:~/drbd-utils# make
[ALL]:~/drbd-utils# debuild -i -us -uc -b
```

And for the kernel driver:

```
[ALL]:~# git clone --recursive git://git.drbd.org/drbd-8.4.git
[ALL]:~# cd drbd-8.4
[ALL]:~/drbd-8.4# git checkout drbd-8.4.7
[ALL]:~/drbd-8.4# make && make clean
[ALL]:~/drbd-8.4# debuild -i -us -uc -b
```

This has created `.deb` packages in the parent directory of the current working directory. All is left is to install them:

```
[ALL]:~/drbd-8.4# dpkg -i ../drbd-dkms_8.4.1-1_all.deb ../drbd-utils_8.9.6-1_amd64.deb
```

At the end we pin the kernel so we don't accidentally run upgrade:

```
[ALL]:~/drbd-8.4# vi /etc/apt/preferences.d/kernel
Package: linux-generic linux-headers-generic linux-image-generic linux-restricted-modules-generic
Pin: version 3.13.0-86
Pin-Priority: 1001
```

To confirm the installation we run:

```
root@server01:~# modinfo drbd
filename:       /lib/modules/3.13.0-86-generic/updates/drbd.ko
alias:          block-major-147-*
license:        GPL
version:        8.4.7-2
description:    drbd - Distributed Replicated Block Device v8.4.7-2
author:         Philipp Reisner <phil@linbit.com>, Lars Ellenberg <lars@linbit.com>
srcversion:     74731AD693E4C2E56E1C448
depends:        libcrc32c
vermagic:       3.13.0-86-generic SMP mod_unload modversions
parm:           minor_count:Approximate number of drbd devices (1-255) (uint)
parm:           disable_sendpage:bool
parm:           allow_oos:DONT USE! (bool)
parm:           proc_details:int
parm:           enable_faults:int
parm:           fault_rate:int
parm:           fault_count:int
parm:           fault_devs:int
parm:           usermode_helper:string

root@server01:~# drbdadm --version
DRBDADM_BUILDTAG=GIT-hash:\ c6e62702d5e4fb2cf6b3fa27e67cb0d4b399a30b\ build\ by\ ubuntu@server01\,\ 2016-05-23\ 05:30:41
DRBDADM_API_VERSION=1
DRBD_KERNEL_VERSION_CODE=0x080407
DRBDADM_VERSION_CODE=0x080906
DRBDADM_VERSION=8.9.6
```

Now we can start with the configuration, first is the common config file `/etc/drbd.d/global_common.conf` on one server only:

```
global {
    usage-count no;
    # minor-count dialog-refresh disable-ip-verification
}
common {
    handlers {
        # These are EXAMPLE handlers only.
        # They may have severe implications,
        # like hard resetting the node under certain circumstances.
        # Be careful when chosing your poison.
        pri-on-incon-degr "/usr/lib/drbd/notify-pri-on-incon-degr.sh; /usr/lib/drbd/notify-emergency-reboot.sh; echo b > /proc/sysrq-trigger ; reboot -f";
        pri-lost-after-sb "/usr/lib/drbd/notify-pri-lost-after-sb.sh; /usr/lib/drbd/notify-emergency-reboot.sh; echo b > /proc/sysrq-trigger ; reboot -f";
        local-io-error "/usr/lib/drbd/notify-io-error.sh; /usr/lib/drbd/notify-emergency-shutdown.sh; echo o > /proc/sysrq-trigger ; halt -f";
        #  Hook into Pacemaker's fencing
        fence-peer "/usr/lib/drbd/crm-fence-peer.sh";
        after-resync-target "/usr/lib/drbd/crm-unfence-peer.sh";
        # split-brain "/usr/lib/drbd/notify-split-brain.sh root";
        # out-of-sync "/usr/lib/drbd/notify-out-of-sync.sh root";
        # before-resync-target "/usr/lib/drbd/snapshot-resync-target-lvm.sh -p 15 -- -c 16k";
        # after-resync-target /usr/lib/drbd/unsnapshot-resync-target-lvm.sh;
    }
    startup {
        # wfc-timeout degr-wfc-timeout outdated-wfc-timeout wait-after-sb
        wfc-timeout 300;
        degr-wfc-timeout 120;
        outdated-wfc-timeout 120;
    }
    options {
        # cpu-mask on-no-data-accessible
        on-no-data-accessible io-error;
        #on-no-data-accessible suspend-io;
    }
    disk {
        # size max-bio-bvecs on-io-error fencing disk-barrier disk-flushes
        # disk-drain md-flushes resync-rate resync-after al-extents
        # c-plan-ahead c-delay-target c-fill-target c-max-rate
        # c-min-rate disk-timeout
        fencing resource-and-stonith;
 
        # Setup syncer rate, start with 30% and let the dynamic planer do the job by
        # letting it know our network parameters (1Gbps), and c-fill-target which is
        # calucated as BDP x 2 (twice the Bandwith Delay Product)
        # used http://www.speedguide.net/bdp.php to find the BDP
        resync-rate 33M;
        c-max-rate 110M;
        c-min-rate 10M;
        c-fill-target 16M;
    }
    net {
        # protocol timeout max-epoch-size max-buffers unplug-watermark
        # connect-int ping-int sndbuf-size rcvbuf-size ko-count
        # allow-two-primaries cram-hmac-alg shared-secret after-sb-0pri
        # after-sb-1pri after-sb-2pri always-asbp rr-conflict
        # ping-timeout data-integrity-alg tcp-cork on-congestion
        # congestion-fill congestion-extents csums-alg verify-alg
        # use-rle
        # Protocol "C" tells DRBD not to tell the operating system that
        # the write is complete until the data has reach persistent
        # storage on both nodes. This is the slowest option, but it is
        # also the only one that guarantees consistency between the
        # nodes. It is also required for dual-primary, which we will
        # be using.
        protocol C;
  
        # Tell DRBD to allow dual-primary. This is needed to enable
        # live-migration of our servers.
        allow-two-primaries yes;
  
        # This tells DRBD what to do in the case of a split-brain when
        # neither node was primary, when one node was primary and when
        # both nodes are primary. In our case, we'll be running
        # dual-primary, so we can not safely recover automatically. The
        # only safe option is for the nodes to disconnect from one
        # another and let a human decide which node to invalidate.
        after-sb-0pri discard-zero-changes;
        after-sb-1pri discard-secondary;
        after-sb-2pri disconnect;
    }
}
```

then we create a resource config file `/etc/drbd.d/r0.res` where we utilize previously created LVM:

```
resource r0 {
    startup {
        # This tells DRBD to promote both nodes to 'primary' when this
        # resource starts. However, we will let pacemaker control this
        # so we comment it out, which tells DRBD to leave both nodes
        # as secondary when drbd starts.
        #become-primary-on both;
    }
 
    net {
        # This tells DRBD how to do a block-by-block verification of
        # the data stored on the backing devices. Any verification
        # failures will result in the effected block being marked
        # out-of-sync.
        verify-alg md5;
 
        # This tells DRBD to generate a checksum for each transmitted
        # packet. If the data received data doesn't generate the same
        # sum, a retransmit request is generated. This protects against
        # otherwise-undetected errors in transmission, like
        # bit-flipping. See:
        # http://www.drbd.org/users-guide/s-integrity-check.html
        data-integrity-alg md5;
 
        # Increase send buffer since we are on 1Gbs bonded network
        sndbuf-size 512k;
 
        # Improve write performance of the replicated data on the
        # receiving node
        max-buffers 8000;
        max-epoch-size 8000;
    }
 
    disk {
        # This tells DRBD not to bypass the write-back caching on the
        # RAID controller. Normally, DRBD forces the data to be flushed
        # to disk, rather than allowing the write-back cachine to
        # handle it. Normally this is dangerous, but with BBU-backed
        # caching, it is safe. The first option disables disk flushing
        # and the second disabled metadata flushes.
        disk-flushes no;
        md-flushes no;
        disk-barrier no;
 
        # In case of error DRBD will operate in diskless mode, and carries    
        # all subsequent I/O operations, read and write, on the peer node   
        on-io-error detach;
 
        # Increase metadata activity log to reduce disk writing and
        # improve performance
        al-extents 3389;
    }
 
    volume 0 {
       device      /dev/drbd0;
       disk        /dev/mapper/vg_drbd0-lv_drbd0;
       meta-disk   internal;
    }
 
    on server01 {
       address     10.10.10.91:7788;
    }
 
    on server02 {
       address     10.10.10.26:7788;
    }
} 
```

To note here is we disable the disk flushes and disk barriers to improve performance since our disk controller has BBU backed volatile cache:

```
root@server01:~# /opt/MegaRAID/storcli/storcli64 /c0 show all | grep BBU
BBU Status = 0
BBU  = Yes
BBU = Present
Cache When BBU Bad = Off
 
root@server01:~# /opt/MegaRAID/storcli/storcli64 -LDInfo -L1 -aALL -NoLog | grep 'Current Cache Policy'
Current Cache Policy: WriteBack, ReadAhead, Direct, No Write Cache if Bad BBU
```

Since everything needs to be identical on the second server we simply copy over the files:

```
root@server01:~# rsync -r /etc/drbd.d/ server02:/etc/drbd.d/
```

Then on both servers we load the kernel module, create the resource and its meta data and bring the resource up:

```
[ALL]:~# modprobe drbd
[ALL]:~# drbdadm create-md r0
[ALL]:~# drbdadm up r0
```

By default both resources will come up as `Secondary` so on one node only we make the resource `Primary` which will trigger the initial disk synchronization:

```
root@server01:~# drbdadm primary --force r0
```

This can take lots of time depending on the disk size so to speedup the initial sync, on the sync target we run:

```
root@server02:~# drbdadm disk-options --c-plan-ahead=0 --resync-rate=110M r0
```

to let it take as much as possible of the 1Gb bandwidth we have. After the initial sync has completed we can make the second node `Primary` too:

```
root@server02:~# drbdadm primary r0
```

and check the final status of the resource:

```
root@server01:~# cat /proc/drbd
version: 8.4.7-2 (api:1/proto:86-101)
GIT-hash: e0fc2176f53dda5aa32a59e6466af9d9dc6493be build by root@server01, 2016-05-23 02:14:03
 0: cs:Connected ro:Primary/Primary ds:UpToDate/UpToDate C r-----
    ns:209989680 nr:0 dw:280916 dr:209974404 al:858 bm:0 lo:0 pe:0 ua:0 ap:0 ep:1 wo:d oos:0
```

And to get back to the configured re-sync speed we run on the sync target node:

```
root@server02:~# drbdadm adjust r0
```

At the end some settings to reduce latency. Enabling the deadline scheduler as recommended by LinBit:

```
[ALL]:~# echo deadline > /sys/block/sdb/queue/scheduler
```

Reduce read I/O deadline to 150 milliseconds (the default is 500ms):

```
[ALL]:~# echo 150 > /sys/block/sdb/queue/iosched/read_expire
```

Reduce write I/O deadline to 1500 milliseconds (the default is 3000ms):

```
[ALL]:~# echo 1500 > /sys/block/sdb/queue/iosched/write_expire
```

and we also put them in the `/etc/sysctl.conf` to make them permanent.

## GFS2

On one node only, we create the file system:

```
root@server01:~# mkfs.gfs2 -p lock_dlm -j 2 -t slcluster:slgfs2 /dev/drbd0
This will destroy any data on /dev/drbd0
Are you sure you want to proceed? [y/n]y
Device:                    /dev/drbd0
Block size:                4096
Device size:               199.99 GB (52427191 blocks)
Filesystem size:           199.99 GB (52427189 blocks)
Journals:                  2
Resource groups:           800
Locking protocol:          "lock_dlm"
Lock table:                "slcluster:slgfs2"
UUID:                      701d9bfe-b220-d58a-2734-ad10efc2afdc
```

where `slcluster` is the cluster name we setup in `corosync` previously:

```
root@server02:~# grep cluster /etc/corosync/corosync.conf
    cluster_name: slcluster
```

and `slgfs2` is an unique file system name. On each node, make the file system mount point and configure it in `/etc/fstab` for GFS2 daemon to find it on startup:

```
 ...
# GFS2/DRBD mount point
UUID=701d9bfe-b220-d58a-2734-ad10efc2afdc       /data   gfs2    defaults,noauto,noatime,nodiratime,nobootwait      0 0
```

## Finishing off the Cluster Configuration

Now that we have DRBD and DLM configured we can add them to Pacemaker for management. We also add some constraints and ordering so the resources start and stop in proper order and dependencies. When finished with the configuration and all changes are committed Pacemaker will automatically start the services, mount file systems etc. The final Pacemaker config looks like this:

```
root@server01:~# crm configure show | cat
node $id="1" server01
node $id="2" server02
primitive p_controld ocf:pacemaker:controld \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    params daemon="dlm_controld" \
    meta target-role="Started"
primitive p_drbd_r0 ocf:linbit:drbd \
    params drbd_resource="r0" \
    op monitor interval="10" role="Master" \
    op monitor interval="20" role="Slave" \
    op start interval="0" timeout="240" \
    op stop interval="0" timeout="100"
primitive p_fence_server01 stonith:fence_ipmilan \
    params pcmk_host_list="server01" ipaddr="10.10.10.52" action="reboot" login="<my-admin-user>" passwd="<my-admin-password>" delay="15" \
    op monitor interval="60s"
primitive p_fence_server02 stonith:fence_ipmilan \
    params pcmk_host_list="server02" ipaddr="10.10.10.71" action="reboot" login="<my-admin-user>" passwd="<my-admin-password>" delay="5" \
    op monitor interval="60s"
primitive p_fs_gfs2 ocf:heartbeat:Filesystem \
    params device="/dev/drbd0" directory="/data" fstype="gfs2" options="_netdev,noatime,rw,acl" \
    op monitor interval="20" timeout="40" \
    op start interval="0" timeout="60" \
    op stop interval="0" timeout="60" \
    meta is-managed="true"
ms ms_drbd p_drbd_r0 \
    meta master-max="2" master-node-max="1" clone-max="2" clone-node-max="1" notify="true" interleave="true"
clone cl_dlm p_controld \
    meta globally-unique="false" interleave="true" target-role="Started"
clone cl_fs_gfs2 p_fs_gfs2 \
    meta globally-unique="false" interleave="true" ordered="true" target-role="Started"
location l_fence_server01 p_fence_server01 -inf: server01
location l_fence_server02 p_fence_server02 -inf: server02
colocation cl_fs_gfs2_dlm inf: cl_fs_gfs2 cl_dlm
colocation co_drbd_dlm inf: cl_dlm ms_drbd:Master
order o_dlm_fs_gfs2 inf: cl_dlm:start cl_fs_gfs2:start
order o_drbd_dlm_fs_gfs2 inf: ms_drbd:promote cl_dlm:start cl_fs_gfs2:start
property $id="cib-bootstrap-options" \
    dc-version="1.1.10-42f2063" \
    cluster-infrastructure="corosync" \
    no-quorum-policy="ignore" \
    stonith-enabled="true" \
    last-lrm-refresh="1464141632"
rsc_defaults $id="rsc-options" \
    resource-stickiness="100" \
    migration-threshold="3"
```

Now we can disable the drbd service from autostart since Pacemaker will take care of that for us:

```
[ALL]# update-rc.d drbd disable
```

Some useful commands we can run to check and confirm the status of all resources in Pacemaker:

```
root@server02:~# crm_mon -Qrf1
Stack: corosync
Current DC: server01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
8 Resources configured
 
Online: [ server01 server02 ]
 
Full list of resources:
 
 p_fence_server01    (stonith:fence_ipmilan):    Started server02
 p_fence_server02    (stonith:fence_ipmilan):    Started server01
 Master/Slave Set: ms_drbd [p_drbd_r0]
     Masters: [ server01 server02 ]
 Clone Set: cl_dlm [p_controld]
     Started: [ server01 server02 ]
 Clone Set: cl_fs_gfs2 [p_fs_gfs2]
     Started: [ server01 server02 ]
 
Migration summary:
* Node server02:
* Node server01:
```

The DLM lock manager has its own tool as well:

```
root@server02:~# dlm_tool status
cluster nodeid 2 quorate 1 ring seq 24 24
daemon now 262695 fence_pid 0
node 1 M add 262497 rem 0 fail 0 fence 0 at 0 0
node 2 M add 262497 rem 0 fail 0 fence 0 at 0 0
 
root@server02:~# dlm_tool ls
dlm lockspaces
name          slgfs2
id            0x966db418
flags         0x00000000
change        member 2 joined 1 remove 0 failed 0 seq 1,1
members       1 2
```

Simple check if the GFS2 file system is mounted:

```
root@server02:~# cat /proc/mounts | grep /data
/dev/drbd0 /data gfs2 rw,noatime,acl 0 0
```

And maybe GFS2 overview using one of the GFS2 own tools `gfs2_edit`:

```
root@server01:~# gfs2_edit -p sb master /dev/drbd0
Block #16    (0x10) of 52427191 (0x31ff9b7) (superblock)
 
Superblock:
  mh_magic              0x01161970(hex)
  mh_type               1                   0x1
  mh_format             100                 0x64
  sb_fs_format          1801                0x709
  sb_multihost_format   1900                0x76c
  sb_bsize              4096                0x1000
  sb_bsize_shift        12                  0xc
  master dir:           2                   0x2
        addr:           134                 0x86
  root dir  :           1                   0x1
        addr:           133                 0x85
  sb_lockproto          lock_dlm
  sb_locktable          slcluster:slgfs2
  sb_uuid               701d9bfe-b220-d58a-2734-ad10efc2afdc
 
The superblock has 2 directories
   1/1 [00000000] 1/133 (0x1/0x85): Dir     root
   2/2 [00000000] 2/134 (0x2/0x86): Dir     master
------------------------------------------------------
Block #134    (0x86) of 52427191 (0x31ff9b7) (disk inode)
-------------- Master directory -----------------
Dinode:
  mh_magic              0x01161970(hex)
  mh_type               4                   0x4
  mh_format             400                 0x190
  no_formal_ino         2                   0x2
  no_addr               134                 0x86
  di_mode               040755(decimal)
  di_uid                0                   0x0
  di_gid                0                   0x0
  di_nlink              4                   0x4
  di_size               3864                0xf18
  di_blocks             1                   0x1
  di_atime              1463999842          0x5742dd62
  di_mtime              1463999842          0x5742dd62
  di_ctime              1463999842          0x5742dd62
  di_major              0                   0x0
  di_minor              0                   0x0
  di_goal_meta          134                 0x86
  di_goal_data          134                 0x86
  di_flags              0x00000201(hex)
  di_payload_format     1200                0x4b0
  di_height             0                   0x0
  di_depth              0                   0x0
  di_entries            8                   0x8
  di_eattr              0                   0x0
 
Directory block: lf_depth:0, lf_entries:0,fmt:0 next=0x0 (8 dirents).
   1/1 [0ed4e242] 2/134 (0x2/0x86): Dir     .
   2/2 [9608161c] 2/134 (0x2/0x86): Dir     ..
   3/3 [5efc1d83] 3/135 (0x3/0x87): Dir     jindex
   4/4 [486eee32] 6/65812 (0x6/0x10114): Dir     per_node
   5/5 [446811e9] 13/66331 (0xd/0x1031b): File    inum
   6/6 [1aef248e] 14/66332 (0xe/0x1031c): File    statfs
   7/7 [b1799d75] 15/66333 (0xf/0x1031d): File    rindex
   8/8 [6c1c0fed] 16/66353 (0x10/0x10331): File    quota
------------------------------------------------------
```

### Cluster testing

Hang the first node and monitor how the second node initiates fencing:

```
root@server01:~# echo c > /proc/sysrq-trigger
```

Monitor the logs on the second node:

```
root@server02:~# tail -f /var/log/syslog
...
May 23 07:21:26 server02 pengine[4342]:  warning: process_pe_message: Calculated Transition 17: /var/lib/pacemaker/pengine/pe-warn-3.bz2
May 23 07:21:26 server02 crmd[4343]:   notice: te_fence_node: Executing reboot fencing operation (56) on server01 (timeout=60000)
May 23 07:21:26 server02 crmd[4343]:   notice: te_rsc_command: Initiating action 69: notify p_drbd_r0_pre_notify_demote_0 on server02 (local)
May 23 07:21:26 server02 stonith-ng[4339]:   notice: handle_request: Client crmd.4343.6f0f4fdc wants to fence (reboot) 'server01' with device '(any)'
May 23 07:21:26 server02 stonith-ng[4339]:   notice: initiate_remote_stonith_op: Initiating remote operation reboot for server01: c2fb8a55-7d37-479b-a913-42dc30b61e70 (0)
```

We can see fencing in action and the stalled node being rebooted. We check the cluster state:

```
root@server02:~# crm status
Last updated: Mon May 23 07:24:21 2016
Last change: Mon May 23 07:21:52 2016 via cibadmin on server02
Stack: corosync
Current DC: server02 (2) - partition WITHOUT quorum
Version: 1.1.10-42f2063
2 Nodes configured
8 Resources configured
 
 
Online: [ server02 ]
OFFLINE: [ server01 ]
 
 p_fence_server01    (stonith:fence_ipmilan):    Started server02
 Master/Slave Set: ms_drbd [p_drbd_r0]
     Masters: [ server02 ]
     Stopped: [ server01 ]
 Clone Set: cl_dlm [p_controld]
     Started: [ server02 ]
     Stopped: [ server01 ]
 Clone Set: cl_fs_gfs2 [p_fs_gfs2]
     Started: [ server02 ]
     Stopped: [ server01 ]
```

and can see all is still running on the surviving node.

### Cluster Monitoring

We can use the `crm_mon` cluster tool for this purpose started in daemon mode on both nodes and managed by `Supervisord`. We create our `/etc/supervisor/conf.d/local.conf` file:

```
[program:crm_mon]
command=crm_mon --daemonize --timing-details --watch-fencing --mail-to igorc@encompasscorporation.com --mail-host smtp.mydomain.com --mail-prefix "Pacemaker cluster alert"
process_name=%(program_name)s
autostart=true
autorestart=true
startsecs=0
stopsignal=QUIT
user=root
stdout_logfile=/var/log/crm_mon.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=3
stderr_logfile=/var/log/crm_mon.log
stderr_logfile_maxbytes=1MB
stderr_logfile_backups=3
```

Then we reload `Supervisord` and start the process:

```
root@server02:~# supervisorctl reread
crm_mon: available
http-server: changed
 
root@server02:~# supervisorctl reload
Restarted supervisord
 
root@server02:~# supervisorctl status
crm_mon                          RUNNING    pid 18259, uptime 0:00:00
```

The daemon will now send me emails every time the cluster state changes. It can also create a web page if used with `--as-html=/path/to/page` parameter for monitoring the state using browser.