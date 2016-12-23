---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'SRIOV Enhanced Networking in AWS EC2 on Ubuntu-14.04 HVM'
categories: 
  - Virtualization
tags: [aws,virtualization]
date: 2015-2-9
---

The latest EC2 generation of HVM instances makes use of the Enhanced Networking, utilizing the `ixgbevf e1000 Gigabit Virtual Function Network Driver` which provides significantly faster network layer processing. We can see it is already in use on `Ubuntu-14.04` with kernel 3.0.43:

```
$ modinfo ixgbevf
filename:       /lib/modules/3.13.0-45-generic/kernel/drivers/net/ethernet/intel/ixgbevf/ixgbevf.ko
version:        2.11.3-k
license:        GPL
description:    Intel(R) 82599 Virtual Function Driver
author:         Intel Corporation, <linux.nics@intel.com>
srcversion:     AE2D8A25951B508611E943D
alias:          pci:v00008086d00001515sv*sd*bc*sc*i*
alias:          pci:v00008086d000010EDsv*sd*bc*sc*i*
depends:       
intree:         Y
vermagic:       3.13.0-45-generic SMP mod_unload modversions
signer:         Magrathea: Glacier signing key
sig_key:        34:99:21:39:F3:DA:40:B6:20:BD:55:17:59:7B:A8:5A:F5:79:7C:9A
sig_hashalgo:   sha512
parm:           debug:Debug level (0=none,...,16=all) (int)
 
$ sudo ethtool -i eth0
driver: ixgbevf
version: 2.11.3-k
firmware-version:
bus-info: 0000:00:03.0
supports-statistics: yes
supports-test: yes
supports-eeprom-access: no
supports-register-dump: yes
supports-priv-flags: no
```

We need to upgrade to at least version 2.14.2 as recommended on the AWS web site since it contains lots of important bug fixes. First we upgrade to the latest kernel (3.0.45 atm)  and reboot:

```
$ sudo aptitude update && sudo aptitude safe-upgrade -y
$ sudo reboot
```

Then we download the latest version of the ixgbevf module, compile and install via DKMS:

```
$ sudo aptitude install -y dkms
$ wget http://sourceforge.net/projects/e1000/files/ixgbevf%20stable/2.16.1/ixgbevf-2.16.1.tar.gz
$ tar -xzf ixgbevf-2.16.1.tar.gz
$ sudo mv ixgbevf-2.16.1 /usr/src/
```

Now, the compile on Ubuntu-14.04 fails since the distro is passing wrong kernel version to the compiler. There was a long awaited patch released on February 3th fixing this at [Ubuntu-14.04.1 ixgbevf patch](https://gist.github.com/cdgraff/1c31727901e5c76d5ea8). We backup the header file and apply the patch:

```
$ sudo cp /usr/src/ixgbevf-2.16.1/src/kcompat.h /usr/src/ixgbevf-2.16.1/src/kcompat.h.orig
```

and after patching:

```
$ sudo diff -u /usr/src/ixgbevf-2.16.1/src/kcompat.h.orig /usr/src/ixgbevf-2.16.1/src/kcompat.h
--- /usr/src/ixgbevf-2.16.1/src/kcompat.h.orig    2015-03-03 01:18:53.419899459 +0000
+++ /usr/src/ixgbevf-2.16.1/src/kcompat.h    2015-03-03 01:22:32.979899459 +0000
@@ -3219,8 +3219,6 @@
 #define u64_stats_update_begin(a) do { } while(0)
 #define u64_stats_update_end(a) do { } while(0)
 #define u64_stats_fetch_begin(a) do { } while(0)
-#define u64_stats_fetch_retry_bh(a) (0)
-#define u64_stats_fetch_begin_bh(a) (0)
  
 #if (RHEL_RELEASE_CODE && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(6,1))
 #define HAVE_8021P_SUPPORT
@@ -4174,8 +4172,8 @@
  
 /*****************************************************************************/
 #if ( LINUX_VERSION_CODE < KERNEL_VERSION(3,15,0) )
-#define u64_stats_fetch_begin_irq u64_stats_fetch_begin_bh
-#define u64_stats_fetch_retry_irq u64_stats_fetch_retry_bh
+#define u64_stats_fetch_begin_irq(a) (0)
+#define u64_stats_fetch_retry_irq(a, b) (0)
 #else
 #define HAVE_PTP_1588_CLOCK_PINS
 #define HAVE_NETDEV_PORT
```

Now we can proceed with the build. We create DKMS driver config file `/usr/src/ixgbevf-2.16.1/dkms.conf` for the new module:

```
PACKAGE_NAME="ixgbevf"
PACKAGE_VERSION="2.16.1"
CLEAN="cd src/; make clean"
MAKE="cd src/; make BUILD_KERNEL=${kernelver}"
BUILT_MODULE_LOCATION[0]="src/"
BUILT_MODULE_NAME[0]="ixgbevf"
DEST_MODULE_LOCATION[0]="/updates"
DEST_MODULE_NAME[0]="ixgbevf"
AUTOINSTALL="yes"
```

then we build and install:

```
$ sudo dkms build -m ixgbevf -v 2.16.1
$ sudo dkms install -m ixgbevf -v 2.16.1
$ sudo update-initramfs -c -k all
```
Now if we check the module version in use:

```
$ modinfo ixgbevf
filename:       /lib/modules/3.13.0-46-generic/updates/dkms/ixgbevf.ko
version:        2.16.1
license:        GPL
description:    Intel(R) 10 Gigabit Virtual Function Network Driver
author:         Intel Corporation, <linux.nics@intel.com>
srcversion:     3F8AACF779F38FD444B1CD3
alias:          pci:v00008086d00001515sv*sd*bc*sc*i*
alias:          pci:v00008086d000010EDsv*sd*bc*sc*i*
depends:       
vermagic:       3.13.0-46-generic SMP mod_unload modversions
parm:           InterruptThrottleRate:Maximum interrupts per second, per vector, (956-488281, 0=off, 1=dynamic), default 1 (array of int)
```

Finally we need to reboot once more to put the new module in use:

```
$ sudo shutdown -r now
 
$ sudo ethtool -i eth0
driver: ixgbevf
version: 2.16.1
firmware-version: N/A
bus-info: 0000:00:03.0
supports-statistics: yes
supports-test: yes
supports-eeprom-access: no
supports-register-dump: yes
supports-priv-flags: no
```

The final step is enabling the instance SRIOV parameter so it can start utilizing the new driver:

```
$ aws ec2 stop-instances --instance-ids instance_id
$ aws ec2 modify-instance-attribute --instance-id instance_id --sriov-net-support simple
$ aws ec2 start-instances --instance-ids instance_id
```

The HVM (this is not supported by PV instances) instances we use for our Joomla! setup had this already activated so it was not necessary in this case.

For the end, although obviously providing huge benefit, this module needs to be rebuilt and reinstall upon every kernel upgrade.