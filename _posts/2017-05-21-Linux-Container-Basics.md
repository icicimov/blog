---
type: posts
header:
  teaser: 'containers.jpg'
title: 'Linux Container Basics'
categories: 
  - Virtualization
tags: ['containers']
date: 2017-05-21
---

Containers are nothing but isolated groups of processes running on a single host. That isolation leverages several underlying technologies built into the Linux kernel like namespaces, cgroups, chroot, capabilities, seccomp and some kernel security extensions like apparmor and selinux. There are also some user space tools like unshare, setns, nsenter, iproute2, capsh that provide the needed interface/wrappers to these kernel functions.

I'm using a Ubuntu-14.04 VM in AWS EC2. We need to compile `nsenter` on Ubuntu-14.04 as it is not included in `util-linux` package:

```bash
sudo apt-get install git build-essential libncurses5-dev libslang2-dev gettext \
zlib1g-dev libselinux1-dev debhelper lsb-release pkg-config po-debconf autoconf \
automake autopoint libtool bison
git clone git://git.kernel.org/pub/scm/utils/util-linux/util-linux.git util-linux
cd util-linux/
./autogen.sh
./configure --without-python --disable-all-programs --enable-nsenter --enable-unshare
make
sudo cp nsenter /usr/bin/
sudo cp unshare /usr/bin/
```

I compiled `unshare` as well since the default one has limited capabilities. Another useful tool we can compile from this package is `lsns` if we need it. For cgroups:

```
sudo apt-get install cgroup-bin   # cgroup-tools on 16.04+
```

First we need a root file system for our container(s) to begin with. We can grab one from docker:

```bash
ubuntu@ip-172-31-8-78:~$ sudo apt-get install docker.io
ubuntu@ip-172-31-8-78:~$ mkdir containers && cd containers

ubuntu@ip-172-31-8-78:~/containers$ mkdir -p rootfs && docker export $(docker create alpine) | tar -C rootfs -xf -
Unable to find image 'alpine:latest' locally
latest: Pulling from alpine
2ff09547bf97: Pulling fs layer
24004a7f7fd8: Pulling fs layer
24004a7f7fd8: Verifying Checksum
24004a7f7fd8: Download complete
2ff09547bf97: Verifying Checksum
2ff09547bf97: Download complete
2ff09547bf97: Pull complete
24004a7f7fd8: Pull complete
Digest: sha256:ccf1a7a4018644cdc8e1d50419bbccb08d8350109e6c2e757eef87ee2629828a
Status: Downloaded newer image for alpine:latest
```

Lets mark this rootfs we created with a file so we know when we are inside it:

```bash
ubuntu@ip-172-31-8-78:~/containers$ touch rootfs/I_AM_ALPINE
ubuntu@ip-172-31-8-78:~/containers$ ls rootfs/
bin  dev  etc  home  I_AM_ALPINE  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
```

Repeat the same one more time to create another one called `rootfs2`:

```bash
root@ip-172-31-8-78:~/containers# mkdir -p rootfs2 && docker export $(docker create busybox) | tar -C rootfs2 -xf -
Unable to find image 'busybox:latest' locally
latest: Pulling from library/busybox
bdbbaa22dec6: Pulling fs layer
bdbbaa22dec6: Download complete
bdbbaa22dec6: Pull complete
Digest: sha256:6915be4043561d64e0ab0f8f098dc2ac48e077fe23f488ac24b665166898115a
Status: Downloaded newer image for busybox:latest

ubuntu@ip-172-31-8-78:~/containers$ touch rootfs2/I_AM_BUSYBOX
ubuntu@ip-172-31-8-78:~/containers$ ls rootfs2/
bin  dev  etc  home  I_AM_BUSYBOX  proc  root  sys  tmp  usr  var
```

## Using chroot

The first tool we'll be working with is `chroot`. A thin wrapper around the similarly named syscall, it allows us to restrict a proces's view of the file system. In this case, we'll restrict our process to the `rootfs` directory then exec a shell.

```bash
ubuntu@ip-172-31-8-78:~/containers$ sudo chroot rootfs /bin/ash
/ # ls
I_AM_ALPINE  dev          home         media        opt          root         sbin         sys          usr
bin          etc          lib          mnt          proc         run          srv          tmp          var
/ # which cp
/bin/cp
/ # ps
PID   USER     TIME  COMMAND
/ # exit
ubuntu@ip-172-31-8-78:~/containers$ 
```

As we can see the `rootfs` directory was seen as `/` in chroot. 

## Creating namespaces with unshare

The linux chroot does not offer process isolation though from the rest of the hosts processes. If we run a command in one terminal on the host:

```bash
root@ip-172-31-8-78:~# top -H -c
```

and then run chroot from another:

```bash
ubuntu@ip-172-31-8-78:~/containers$ sudo chroot rootfs /bin/ash
/ # id
uid=0(root) gid=0(root) groups=0(root)
/ # mount -t proc proc /proc
/ # ps auxww | grep top
22290 root      0:00 top -H -c
22296 root      0:00 grep top
/ # kill -TERM 22290
/ # ps auxww | grep top
/ # 
```

So by mounting the host's `/proc` file system inside the container we are able to see the processes running on the host itself and since we are also the same `root` user inside and outside the chroot we can even terminate/kill any of those host processes.

```bash
root@ip-172-31-8-78:~# ps aux | grep chroot
root     22291  0.0  0.2  67996  2204 pts/1    S    04:22   0:00 sudo chroot rootfs /bin/ash
```

This is where linux `namespaces` come into play. Namespaces allow us to create restricted views of systems like the process tree, network interfaces and mounts.

Creating namespace is easy with the `unshare` command. The main use of `unshare` is to allow a process to control its shared execution context without creating a new process. It gives us a nice wrapper around the `clone()` and/or `fork()` syscall and lets us setup namespaces manually.

Let's run the chroot command again but this time using unshare and namespaces:

```bash
ubuntu@ip-172-31-8-78:~/containers$ sudo unshare --mount --pid --fork \
  --mount-proc=rootfs/proc chroot rootfs /bin/ash
/ # ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/ash
    2 root      0:00 ps aux
/ # 
```

Having created a new process namespace we can see our shell running with `PID 1`. Another effect of the separate PID namespace is that we can not see the host processes any more from inside the chroot.

## Entering namespaces with nsenter

A powerful aspect of namespaces is their composability; processes may choose to separate some namespaces but share others. For instance it may be useful for two programs to have isolated PID namespaces, but share a network namespace (e.g. Kubernetes pods). This brings us to the `setns()` syscall and the `nsenter` command line tool.

Let's find the shell running in a chroot from our last example.

```bash
root@ip-172-31-8-78:~# ps aux | grep -w '/bin/ash'
root      4484  0.0  0.2  67996  2204 pts/1    S    06:23   0:00 sudo unshare --pid --fork --mount-proc=/home/ubuntu/containers/rootfs/proc chroot /home/ubuntu/containers/rootfs /bin/ash
root      4485  0.0  0.0   5924   612 pts/1    S    06:23   0:00 unshare --pid --fork --mount-proc=/home/ubuntu/containers/rootfs/proc chroot /home/ubuntu/containers/rootfs /bin/ash
root      4486  0.0  0.0   1628   512 pts/1    S+   06:23   0:00 /bin/ash
```

The kernel exposes namespaces under `/proc/$PID/ns` as files. In this case, `/proc/4038/ns/pid` is the process namespace we're hoping to join.

```bash
root@ip-172-31-8-78:~# ls -l /proc/4486/ns/
total 0
lrwxrwxrwx 1 root root 0 Jul 19 06:34 ipc -> ipc:[4026531839]
lrwxrwxrwx 1 root root 0 Jul 19 06:34 mnt -> mnt:[4026532160]
lrwxrwxrwx 1 root root 0 Jul 19 06:34 net -> net:[4026531956]
lrwxrwxrwx 1 root root 0 Jul 19 06:32 pid -> pid:[4026532161]
lrwxrwxrwx 1 root root 0 Jul 19 06:34 user -> user:[4026531837]
lrwxrwxrwx 1 root root 0 Jul 19 06:34 uts -> uts:[4026531838]
```

The nsenter command provides a wrapper around setns to enter a namespace. We'll provide the namespace file, then run the unshare to remount /proc and chroot to setup a chroot. This time, instead of creating a new namespace, our shell will join the existing one.

```bash
ubuntu@ip-172-31-8-78:~/containers# mount -o bind $PWD/rootfs2/proc $PWD/rootfs2/proc
ubuntu@ip-172-31-8-78:~/containers$ sudo nsenter --pid=/proc/4486/ns/pid unshare \
  --fork --mount-proc=$PWD/rootfs2/proc chroot $PWD/rootfs2 /bin/sh
/ # ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/ash
    6 root      0:00 unshare --fork --mount-proc=/home/ubuntu/containers/rootfs2/proc chroot /home/ubuntu/containers/rootfs2 /bin/sh
    7 root      0:00 /bin/sh
   10 root      0:00 ps aux
/ # ls /
I_AM_BUSYBOX  dev           home          root          tmp           var
bin           etc           proc          sys           usr
/ # 
```

If we check the first shell we can see the new processes:

```bash
/ # ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/ash
    6 root      0:00 unshare --fork --mount-proc=/home/ubuntu/containers/rootfs2/proc chroot /home/ubuntu/containers2/rootfs /bin/sh
    7 root      0:00 /bin/sh
    8 root      0:00 ps aux
/ # ls /
I_AM_ALPINE  dev          home         media        opt          root         sbin         sys          usr
bin          etc          lib          mnt          proc         run          srv          tmp          var
/ # 
```

Having entered the namespace successfully, when we run `ps` in the second shell (PID 7) we see the first shell (PID 1).

Now if we run `top` command in the second shell we can see the new process in the first shell too:

```bash
/ # ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/ash
   38 root      0:00 unshare --fork --mount-proc=/home/ubuntu/containers/rootfs2/proc chroot /home/ubuntu/containers/rootfs2 /bin/sh
   39 root      0:00 /bin/sh
   44 root      0:00 top
   45 root      0:00 ps aux
/ # 
```

## Networking

We will create a `veth pair` of virtual interfaces on the host `sandbox0` and `sandbox1`, put one end inside the container network namespace called `sandbox` and set up the appropriate routing on the host so the container can get Internet access.

```bash
# create new network namespace
ip netns add sandbox

# configure sandbox loopback
ip netns exec sandbox ip addr add 127.0.0.1/8 dev lo
ip netns exec sandbox ip link set lo up

# create a veth device pair
ip link add sandbox0 type veth peer name sandbox1

# initiate the host side
ip link set sandbox0 up

# initiate the container side
ip link set sandbox1 netns sandbox up

# configure network
ip addr add 192.168.22.1/30 dev sandbox0
ip netns exec sandbox ip addr add 192.168.22.2/30 dev sandbox1
ip netns exec sandbox ip route add default via 192.168.22.1 dev sandbox1

# enable routing
echo 1 | tee /proc/sys/net/ipv4/ip_forward
ext_if=$(ip route get 8.8.8.8 | grep 'dev' | awk '{ print $5 }')
iptables -I POSTROUTING -t nat -s 192.168.22.2/32 -o ${ext_if} -j MASQUERADE
iptables -I FORWARD -i sandbox0 -o ${ext_if} -j ACCEPT
iptables -I FORWARD -i ${ext_if} -o sandbox0 -j ACCEPT

# configure resolv.conf
mkdir -p /etc/netns/sandbox
echo nameserver 8.8.8.8 | tee /etc/netns/sandbox/resolv.conf
```

Now we can check the host side of the veth pair `sandbox0`:

```bash
root@ip-172-31-8-78:~/containers# ip -d link show dev sandbox0
5: sandbox0@if4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether 3a:08:b6:5e:1c:2d brd ff:ff:ff:ff:ff:ff link-netnsid 0 promiscuity 0 
    veth addrgenmode eui64
```
and the container network namespace side `sandbox1`:

```bash
root@ip-172-31-8-78:~/containers# ip netns exec sandbox ip -d link show dev sandbox1
4: sandbox1@if5: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether 32:e9:5c:c0:5d:f8 brd ff:ff:ff:ff:ff:ff link-netnsid 0 promiscuity 0 
    veth addrgenmode eui64 
```

Start the container again:

```bash
root@ip-172-31-8-78:~/containers# cgexec -g cpu,memory,blkio,devices,freezer:/sandbox prlimit --nofile=256 --nproc=512 --locks=32 \
   ip netns exec sandbox unshare --mount --uts --ipc --pid --mount-proc=$PWD/rootfs/proc --fork chroot $PWD/rootfs /bin/ash
/ # ip a s
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN qlen 1
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
4: sandbox1@if5: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue state UP qlen 1000
    link/ether 32:e9:5c:c0:5d:f8 brd ff:ff:ff:ff:ff:ff
    inet 192.168.22.2/30 scope global sandbox1
       valid_lft forever preferred_lft forever
    inet6 fe80::30e9:5cff:fec0:5df8/64 scope link 
       valid_lft forever preferred_lft forever
/ # ping yahoo.com
PING yahoo.com (98.137.246.8): 56 data bytes
64 bytes from 98.137.246.8: seq=0 ttl=42 time=172.700 ms
64 bytes from 98.137.246.8: seq=1 ttl=42 time=172.647 ms
64 bytes from 98.137.246.8: seq=2 ttl=42 time=172.913 ms
/ # apk add --no-cache bash
fetch http://dl-cdn.alpinelinux.org/alpine/v3.11/main/x86_64/APKINDEX.tar.gz
fetch http://dl-cdn.alpinelinux.org/alpine/v3.11/community/x86_64/APKINDEX.tar.gz
(1/5) Installing ncurses-terminfo-base (6.1_p20191130-r0)
(2/5) Installing ncurses-terminfo (6.1_p20191130-r0)
(3/5) Installing ncurses-libs (6.1_p20191130-r0)
(4/5) Installing readline (8.0.1-r0)
(5/5) Installing bash (5.0.11-r1)
Executing bash-5.0.11-r1.post-install
Executing busybox-1.31.1-r9.trigger
OK: 15 MiB in 19 packages
/ # exit
```

Now that we have the networking part sorted, we successfully installed `bash` inside our container and the binary is now present under `$PWD/rootfs/bin/bash` in the rootfs.

## Volumes

These are provided in Linux via bind mounts.

Create a directory inside the chroot that will be our mount point inside:

```bash
# mkdir /var/test
```

On the host from a separate terminal:

```bash
$ mkdir test && echo "testing" > test/file
$ sudo mount --bind -o ro $PWD/test $PWD/rootfs/var/test
```

Now we are able to see the content of the `test` directory on the host from inside the chroot file system where it got bind-mounted.

## Security and Capabilities 

Next we want to limit the capabilities of the "root" user in our container. For that purpose we can use `capsh` utility. Adding it to our container launch command it now looks like this:

```bash
root@ip-172-31-8-78:~/containers# cgexec -g cpu,memory,blkio,devices,freezer:/sandbox \
  prlimit --nofile=256 --nproc=512 --locks=32 ip netns exec sandbox \
    unshare --mount --uts --ipc --pid --mount-proc=$PWD/rootfs/proc --fork \
      capsh --drop=cap_chown,cap_setpcap,cap_setfcap,cap_sys_admin --chroot=$PWD/rootfs --
bash-5.0# ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/bash
   11 root      0:00 ps aux
bash-5.0# id
uid=0(root) gid=0(root) groups=0(root)
bash-5.0# ls /
I_AM_ALPINE  dev          home         media        opt          root         sbin         sys          usr
bin          etc          lib          mnt          proc         run          srv          tmp          var
bash-5.0# ls -l /I_AM_ALPINE 
-rw-r--r--    1 root     root             0 Jan 20 01:12 /I_AM_ALPINE
bash-5.0# getent passwd nobody
nobody:x:65534:65534:nobody:/:/sbin/nologin
bash-5.0# chown nobody\: /I_AM_ALPINE 
chown: /I_AM_ALPINE: Operation not permitted
bash-5.0#
```

We can see the `chown` command failed since we dropped the `cap_chown` for the process in the chroot. Appart from capabilities there some other tools we can utilize to make the containers more secure like user space AppArmor and SELinux or even `seccomp` recently.

### Unprivileged User

User namespaces are an isolation feature that allow processes to run with different user identifiers and/or privileges inside that namespace than are permitted outside. A user may have a uid of 1001 on a system outside of a user namespace, but run programs with a different uid with different privileges inside the namespace.

The best way to prevent privilege-escalation attacks from within a container is to configure our container’s applications to run as unprivileged users. For containers whose processes must run as the root user within the container, we can re-map this user to a less-privileged user on the linux host. The mapped user is assigned a range of UIDs which function within the namespace as normal UIDs from 0 to 65536, but have no privileges on the host machine itself.

The remapping is specified in the following files for the default `ubuntu` user:

```bash
root@ip-172-31-8-78:~# cat /etc/subuid
ubuntu:100000:65536
root@ip-172-31-8-78:~# cat /etc/subgid
ubuntu:100000:65536
```

This means that `ubuntu` is assigned a subordinate user ID range of 100000 and the next 65536 integers in sequence. UID 100000 is mapped within the namespace as UID 0 (root). UID 100001 is mapped as UID 1, and so forth. If a process attempts to escalate privilege outside of the namespace, the process is running as an unprivileged high-number UID on the host, which does not even map to a real user. This means the process has no privileges on the host system at all.

Now I don't have to be `root` user to run a chroot:

```bash
ubuntu@ip-172-31-8-78:~/containers$ unshare --user --map-root-user --uts --pid --fork --mount-proc=$PWD/rootfs/proc chroot $PWD/rootfs /bin/ash
/ # id
uid=0(root) gid=0(root) groups=65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),65534(nobody),0(root)
/ # ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/ash
    3 root      0:00 ps aux
/ # exit
```

and the `root` user in the namespace is mapped to an unprivileged user id on the host.

## Conclusion

We have seen how to create a fully functional process (container) from the command line, using Linux built in tools. It can even be isolated inside it's own root file system, with it's own PID and network namespace, limited in system resources it can use on the host and with limited scope of actions it can perform in the chroot as root user. This is what container runtimes like LXC and Docker engine provide for us executing the above rather complex work in the background and making the life easier for everyone.