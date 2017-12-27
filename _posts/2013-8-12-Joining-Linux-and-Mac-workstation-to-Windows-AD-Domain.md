---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Joining Linux and Mac workstation to Windows AD Domain'
categories: 
  - Server
tags: ['samba', 'windows', 'AD/DC']
date: 2013-8-12
---

The Likewise package can be used to join Mac and Linux boxes to Windows AD domain. The company has been acquired by Beyond Trust couple of years ago and is now known as PBIS (PowerBroker Identity Services). Apart from the commercial Enterprise version they are still maintaining an open source public one too.

If looking to install the classic Likewise instead, there are still some Ubuntu ppa maintained at [Likewise-open-ppa](https://launchpad.net/~likewise-open/+archive/likewise-open-ppa) but no 6.x package for 12.04 is available for now.

# Installation

We start by installing some packages on the client:

```
igorc@lin1pc:~/Downloads$ sudo aptitude install libpam-krb5 build-essential fakeroot devscripts debhelper autoconf automake libtool libncurses5-dev uuid-dev flex bison libpam0g-dev libssl-dev libxml2-dev libpopt-dev libpam-mount keyutils cifs_utils smbfs
```

Download LikeWise-Open install script from [pbis-open](http://download.beyondtrust.com/PBISO/7.5.1.1517/linux.deb.x64/pbis-open-7.5.1.1517.linux.x86_64.deb.sh)

The latest version is part of PBIS package. Running the script creates `pbis-open-7.5.1.1517.linux.x86_64.deb` which then installs the Likewise binaries under `/opt/pbis` and creates `/opt/likewise` symbolic link for backwards compatibility.

```
igorc@lin1pc:~/Downloads$ chmod u+x pbis-open-7.5.1.1517.linux.x86_64.deb.sh
igorc@lin1pc:~/Downloads$ sudo ./pbis-open-7.5.1.1517.linux.x86_64.deb.sh
```

After that we join the box as follows:

```
igorc@lin1pc:~/Downloads$ sudo /opt/likewise/bin/domainjoin-cli join encompass.com Administrator
Joining to AD Domain:   encompass.com
With Computer DNS Name: lin1pc.encompass.com
 
Administrator@ENCOMPASS.COM's password:
Warning: System restart required
Your system has been configured to authenticate to Active Directory for the first time.  It is recommended that you restart
your system to ensure that all applications recognize the new settings.
```

Success!

Some post install settings and tweaks:

```
igorc@lin1pc:~$ sudo /opt/pbis/bin/config LoginShellTemplate /bin/bash
igorc@lin1pc:~$ sudo /opt/pbis/bin/config MemoryCacheSizeCap 1048576
```

By default, the user's Windows home directory is not mounted locally. We can enable it and specify it's local mount point.

```
igorc@lin1pc:~$ sudo /opt/pbis/bin/config RemoteHomeDirTemplate "%H/local/%D/%U/WindowsHome"
```

The last one is not necessary with the latest PBIS release since it's been set by default. This allows us to login without having to put our Windows DOMAIN name in front of our user name.

```
igorc@lin1pc:~$ sudo /opt/pbis/bin/config AssumeDefaultDomain true
```

Then we can confirm the `LIN1PC` was added in the Computers group of the AD via Windows MMC.

![Linux box in AD domain](/blog/images/linux-box-in-ad-domain.png "Linux box in AD domain")

After restart the Likewise daemon will be running and the box will be joined to the domain. We can check and confirm the AD users have been created:

```
igorc@lin1pc:~$ /opt/pbis/bin/find-user-by-name icicimov
User info (Level-0):
====================
Name:              icicimov
SID:               S-1-5-21-4154966781-565189077-2949095343-1104
Uid:               1128268880
Gid:               1128268289
Gecos:             Igor Cicimov
Shell:             /bin/bash
Home dir:          /home/local/ENCOMPASS/icicimov
Logon restriction: NO
 
igorc@lin1pc:~$ /opt/pbis/bin/find-user-by-name Administrator
User info (Level-0):
====================
Name:              administrator
SID:               S-1-5-21-4154966781-565189077-2949095343-500
Uid:               1128268276
Gid:               1128268289
Gecos:             <null>
Shell:             /bin/bash
Home dir:          /home/local/ENCOMPASS/administrator
Logon restriction: NO
 
igorc@lin1pc:~$ id ENCOMPASS\\Administrator
uid=1128268276(administrator) gid=1128268289(domain^users) groups=1128268289(domain^users)
 
igorc@lin1pc:~$ id ENCOMPASS\\icicimov
uid=1128268880(icicimov) gid=1128268289(domain^users) groups=1128268289(domain^users)
```

or we can run it without domain name since it is default:

```
igorc@lin1pc:~$ id -a icicimov
uid=1128268880(icicimov) gid=1128268289(domain^users) groups=1128268289(domain^users)
```

We can also add this AD user to local groups:

```
igorc@lin1pc:~$ sudo usermod -a -G lpadmin icicimov
igorc@lin1pc:~$ id -a icicimov
uid=1128268880(icicimov) gid=1128268289(domain^users) groups=1128268289(domain^users),107(lpadmin)

To check the running services:
root@lin1pc:~# /opt/likewise/bin/lwsm list
lwreg          running (container: 934)
dcerpc         stopped
eventlog       running (container: 973)
lsass          running (container: 1007)
lwio           running (container: 994)
netlogon       running (container: 984)
rdr            running (io: 994)
reapsysl       running (container: 1042)
usermonitor    stopped
```

The Likewise Registry Service (lwregd) is the configuration data store used by all Likewise services. We can view and modify the registry settings by running `/opt/likewise/bin/regshell` as the root user. For example:

```
$ sudo /opt/likewise/bin/regshell
> cd hkey_this_machine\\services
 
hkey_this_machine\services> dir
[hkey_this_machine\services]
[HKEY_THIS_MACHINE\Services\lsass]
...
 
hkey_this_machine\services> cd lsass
 
hkey_this_machine\services\lsass> dir
Arguments    REG_SZ   "lsassd --syslog"
Dependencies REG_SZ   "netlogon lwio lwreg rdr"
Description  REG_SZ    "Likewise Security and Authentication Subsystem"
Path         REG_SZ    "/opt/likewise/sbin/lsassd"
Type         REG_DWORD 0x00000001 (1)
 
[HKEY_THIS_MACHINE\Services\lsass\Parameters]
```

To query the Domain status we can run:

```
root@lin1pc:~# /opt/likewise/bin/lw-get-status
LSA Server Status:
 
Compiled daemon version: 7.5.1.1517
Packaged product version: 7.5.1517.65987
Uptime:        0 days 0 hours 35 minutes 32 seconds
 
[Authentication provider: lsa-activedirectory-provider]
 
Status:        Online
Mode:          Un-provisioned
Domain:        ENCOMPASS.COM
Domain SID:    S-1-5-21-4154966781-565189077-2949095343
Forest:        encompass.com
Site:          Default-First-Site-Name
Online check interval:  300 seconds
[Trusted Domains: 1]
 
[Domain: ENCOMPASS]
 
DNS Domain:       encompass.com
Netbios name:     ENCOMPASS
Forest name:      encompass.com
Trustee DNS name:
Client site name: Default-First-Site-Name
Domain SID:       S-1-5-21-4154966781-565189077-2949095343
Domain GUID:      2353c44d-f5a1-2240-aec4-02815ae3f9de
Trust Flags:      [0x001d]
                 [0x0001 - In forest]
                 [0x0004 - Tree root]
                 [0x0008 - Primary]
                 [0x0010 - Native]
Trust type:       Up Level
Trust Attributes: [0x0000]
Trust Direction:  Primary Domain
Trust Mode:       In my forest Trust (MFT)
Domain flags:     [0x0001]
                 [0x0001 - Primary]
 
[Domain Controller (DC) Information]
 
DC Name:              smb4dc.encompass.com
DC Address:           192.168.0.107
DC Site:              Default-First-Site-Name
DC Flags:             [0x000003fd]
DC Is PDC:            yes
DC is time server:    yes
DC has writeable DS:  yes
DC is Global Catalog: yes
DC is running KDC:    yes
 
[Global Catalog (GC) Information]
 
GC Name:              smb4dc.encompass.com
GC Address:           192.168.0.107
GC Site:              Default-First-Site-Name
GC Flags:             [0x000003fd]
GC Is PDC:            yes
GC is time server:    yes
GC has writeable DS:  yes
GC is running KDC:    yes
root@lin1pc:~#
 
igorc@lin1pc:~$ sudo su - ENCOMPASS\\icicimov
[sudo] password for igorc:
$ bash
icicimov@lin1pc:~$ pwd
/home/local/ENCOMPASS/icicimov
icicimov@lin1pc:~$
```

To dump the complete Likewise service configuration:

```
igorc@lin1pc:~$ /opt/pbis/bin/config --dump
AllowDeleteTo ""
AllowReadTo ""
AllowWriteTo ""
MaxDiskUsage 104857600
MaxEventLifespan 90
MaxNumEvents 100000
DomainSeparator "\\"
SpaceReplacement "^"
EnableEventlog false
Providers "ActiveDirectory"
DisplayMotd false
PAMLogLevel "error"
UserNotAllowedError "Access denied"
AssumeDefaultDomain true
CreateHomeDir true
CreateK5Login true
SyncSystemTime true
TrimUserMembership true
LdapSignAndSeal false
LogADNetworkConnectionEvents true
NssEnumerationEnabled true
NssGroupMembersQueryCacheOnly true
NssUserMembershipQueryCacheOnly false
RefreshUserCredentials true
CacheEntryExpiry 14400
DomainManagerCheckDomainOnlineInterval 300
DomainManagerUnknownDomainCacheTimeout 3600
MachinePasswordLifespan 2592000
MemoryCacheSizeCap 1048576
HomeDirPrefix "/home"
HomeDirTemplate "%H/local/%D/%U"
RemoteHomeDirTemplate "%H/local/%D/%U/WindowsHome"
HomeDirUmask "022"
LoginShellTemplate "/bin/bash"
SkeletonDirs "/etc/skel"
UserDomainPrefix "ENCOMPASS"
DomainManagerIgnoreAllTrusts false
DomainManagerIncludeTrustsList
DomainManagerExcludeTrustsList
RequireMembershipOf
Local_AcceptNTLMv1 true
Local_HomeDirTemplate "%H/local/%D/%U"
Local_HomeDirUmask "022"
Local_LoginShellTemplate "/bin/sh"
Local_SkeletonDirs "/etc/skel"
UserMonitorCheckInterval 1800
LsassAutostart true
EventlogAutostart true
```

Find AD users available:

```
igorc@lin1pc:~$ /opt/pbis/bin/enum-users
User info (Level-0):
====================
Name:              user1
Uid:               1128268882
Gid:               1128268289
Gecos:             Name Surname
Shell:             /bin/bash
Home dir:          /home/local/ENCOMPASS/user1
 
User info (Level-0):
====================
Name:              administrator
Uid:               1128268276
Gid:               1128268289
Gecos:             <null>
Shell:             /bin/bash
Home dir:          /home/local/ENCOMPASS/administrator
 
User info (Level-0):
====================
Name:              icicimov
Uid:               1128268880
Gid:               1128268289
Gecos:             Igor Cicimov
Shell:             /bin/bash
Home dir:          /home/local/ENCOMPASS/icicimov
 
User info (Level-0):
====================
Name:              krbtgt
Uid:               1128268278
Gid:               1128268289
Gecos:             <null>
Shell:             /bin/bash
Home dir:          /home/local/ENCOMPASS/krbtgt
 
User info (Level-0):
====================
Name:              guest
Uid:               1128268277
Gid:               1128268290
Gecos:             <null>
Shell:             /bin/bash
Home dir:          /home/local/ENCOMPASS/guest
 
TotalNumUsersFound: 5
```

Then we can login remotely as AD user icicimov:

```
igorc@igor-laptop:~$ ssh icicimov@192.168.0.10
Password:
Last login: Thu Aug  8 16:42:44 2013 from 192.168.0.21
 
icicimov@lin1pc:~$ pwd
/home/local/ENCOMPASS/icicimov

icicimov@lin1pc:~$ ls -la
total 28
drwxr-xr-x 2 icicimov domain^users 4096 Aug  8 11:30 .
drwxr-xr-x 3 root     root         4096 Aug  8 09:05 ..
-rw------- 1 icicimov domain^users  210 Aug  8 16:44 .bash_history
-rw-r--r-- 1 icicimov domain^users  220 Aug  8 09:06 .bash_logout
-rw-r--r-- 1 icicimov domain^users 3486 Aug  8 09:06 .bashrc
-rw-r--r-- 1 icicimov domain^users   23 Aug  8 11:11 .k5login
-rw-r--r-- 1 icicimov domain^users  675 Aug  8 09:06 .profile
icicimov@lin1pc:~$
```

The home directory `/home/local/ENCOMPASS/icicimov` gets created upon first login.

## Mount SMBFS/CIFS Windows shares on users login

This is useful option if we want to have the users documents directory for example from Windows mounted on Linux when the user loggs in to one. This should be taken care of by Likewise by configuring the `RemoteHomeDirTemplate` as shown before:

```
RemoteHomeDirTemplate "%H/local/%D/%U/WindowsHome"
```

but was not working in my case.

Another way to achieve this is by using the `pam_mount` module.

### Install the needed modules

```
igorc@igor-laptop:~/scripts$ sudo aptitude install libpam-mount smbfs
```

### Configure pam_mount

Add the following in the `Volume definitions` section of the config file:

```
root@lin1pc:~# vi /etc/security/pam_mount.conf.xml
 
        <!-- Volume definitions -->
<volume options="domain=ENCOMPASS,nosuid,nodev" user="*" fstype="cifs" server="smb4dc.encompass.com" path="Users/%(DOMAIN_USER)" mountpoint="/home/local/ENCOMPASS/%(DOMAIN_USER)/Windows" />
```

Here I have chosen to mount the user's `My Documents` directory under users's `$HOME/Windows` but it can be changed to get mounted to `$HOME/Documents` so it seamlessly integrates into his documents directory.

### Fix a misconfiguration in the authentication stack

The problem is that pam_lsass session authenticaton as sufficient happens before pam_mount which is optional, so authentication stops here and doesn't go all the way to the bottom of the stack and the volume mount never gets triggered. To avoid this the config should be as follows:

```
root@lin1pc:~# cat /etc/pam.d/common-auth | grep -v ^# | grep .
auth    [success=3 default=ignore]  pam_krb5.so minimum_uid=1000
auth    [success=2 default=ignore]  pam_unix.so nullok_secure try_first_pass
auth    [success=1 default=ignore]  pam_lsass.so try_first_pass
auth    requisite           pam_deny.so
auth    required            pam_permit.so
auth    optional    pam_mount.so
root@lin1pc:~# cat /etc/pam.d/common-session | grep -v ^# | grep .
session [default=1]         pam_permit.so
session requisite           pam_deny.so
session required            pam_permit.so
session optional            pam_umask.so
session optional            pam_krb5.so minimum_uid=1000
session required    pam_unix.so
session optional    pam_mount.so
session sufficient      pam_lsass.so
session optional                        pam_ck_connector.so nox11
```

and in this file we make sure that `pam_mount.so` line is BEFORE `pam_lsass.so` or the `pam_mount` module will never get triggered.

### Fix the pam_mount authentication issue

This problem happens when the user tries to authenticate over SSH and is related to the fact that the pam_mount asks for password BEFORE the user has even gained ptty which leads to failed authentication in AD due to empty password. There are two workarounds:

1. Disable `ChallengeResponseAuthentication` in SSH

```
root@lin1pc:~# vi /etc/ssh/sshd_conf
...
ChallengeResponseAuthentication no
...
```

2. Run ssh client with password authentication as preferred option

```
$ ssh -o preferredauthentications=password user1@192.168.0.10
```

The second one is much faster in terms of the time it takes for the user to be presented with login prompt. In both cases the mount of the CIFS share is successful as seen in the authentication log:

```
root@lin1pc:~# tail -f /var/log/auth.log
.
.
Aug 12 09:05:54 lin1pc sshd[23875]: pam_mount(mount.c:284): mkdir[1128268882] /home/local/ENCOMPASS/user1/Windows
Aug 12 09:05:54 lin1pc sshd[23875]: pam_mount(misc.c:380): 29 20 0:21 /user1 /home/local/ENCOMPASS/user1/Windows rw,nosuid,nodev,relatime - cifs //smb4dc.encompass.com/Users/user1 rw,sec=ntlm,unc=\\smb4dc.encompass.com\Users,username=user1,domain=ENCOMPASS,uid=1128268882,forceuid,gid=1128268289,forcegid,addr=192.168.0.107,unix,posixpaths,serverino,acl,rsize=1048576,wsize=65536,actimeo=1
.
.
Aug 12 09:04:30 lin1pc sshd[23708]: command: 'umount' '/home/local/ENCOMPASS/user1/Windows'
.
.
```

where we can see the `Windows` directory being successfully created upon users login and the CIFS mounted. Then we can see the successful umount upon users logging off which also leads to the `Windows` directory being removed from the filesystem.

# References and Resources:
* [Documentation](http://www.beyondtrust.com/Resources/OpenSourceDocumentation/)
* [Forum](http://forum.beyondtrust.com/)
