---
type: posts
header:
  teaser: 'Device-Mesh.jpg'
title: 'Unified Linux Login, Privileges and Home Directory with OpenLDAP and NFS/automount'
categories: 
  - DevOps
tags: [ldap, nfs, aws]
date: 2014-8-7
---
{% include toc %}
Maintaining users, shared file systems and authentication in centralized manner is one of the biggest challenges for a organization or network. It usually involves many peaces of different technologies brought together into one centralized unit which often proves to be a very daunting task to execute. But once setup and configured it always becomes indispensable piece of infrastructure.

For our user case this would mean centralized management of all users, files and credentials (ssh keys) as well as services access, ie LDAP based Apache authentication and authorization instead of locally managed password files per instance, for our AWS VPC's. The users and their credentials, including the user groups and sudo privileges, will be hosted in OpenLDAP directory server and the users home file systems will reside in a shared storage on a NFS server and auto mounted over LDAP upon users login. This brings the following advantages:

* All resources need to be created only ones in the LDAP/NFS instead for each instance separately
* Maintaining of the resources becomes easy and `one of` exercise instead of doing it multiple times for each instance (as we do it now via Ansible templates and playbooks to propagate changes to each instance when needed)
* Multipurpose, central storage for users credentials and privileges (can be used for SSO etc.)
* Parameter changes become immediately effective upon users login
* Avoiding incidents like full disk by centrally managing file system parameters (ie size and quotas on the users home file systems)
* It is completely open source

Apart from all this benefits though, there are some considerations that I think need to be mentioned:

* The LDAP/NFS can become a SPOF (Single Point Of Failure), if not available users will not be able to login, so HA needs to be provided (and it will be) and the strategy carefully think of (like leave the default user user that gets automatically created upon instance creation out of this solution so we don't lock our self's out)
* The solution might look complicated (but seems stable and reliable in my testing environment)

# Installation and Setup

The two main components from the infrastructure point of view are the OpenLDAP server and the NFS server. When finished, the whole communication between the clients and the server will go via TLS and no anonymous access will be allowed to the DIT for security reasons.

## NFS setup

For the NFS server I've launched a new `m3.small` instance with Ubuntu-14.04. It will export the users home directories and take care of the storage attributes.

### File system preparation

We will setup a file system with quota's for better control over the file size. First we install the packages needed:

```
root@file-server:~# aptitude install nfs-kernel-server quota quotatool nfs-common lvm2
```

Then create the volume (I have attached 50GB drive to the instance for users home storage):

```
root@file-server:~# pvcreate /dev/xvdb
root@file-server:~# vgcreate vg_files /dev/xvdb
root@file-server:~# lvcreate --name lv_files -l 100%vg vg_files
```

Create the file system:

```
root@file-server:~# mkfs -t ext4 -L FILES /dev/vg_files/lv_files
```

Create the mount point:

```
root@file-server:~# mkdir -p /export/home
```

For the quota tolls to work properly we need to install the linux-image-extra package which is where Ubuntu keeps those packages:

```
root@file-server:~# aptitude install linux-image-extra-virtual
root@file-server:~# modprobe quota_v2
root@file-server:~# modprobe quota_v1
```

and load the modules in `/etc/modules` and make them permanent over reboots:

```
...
quota_v2
quota_v1
```

Next we enable journaling quota on the file system in `/etc/fstab`:

```
...
LABEL=FILES /export/home ext4 errors=remount-ro,user_xattr,usrjquota=quota.user,grpjquota=quota.group,jqfmt=vfsv0 0 1
```

Mount the file system:

```
root@file-server:~# mount -o remount LABEL=FILES
```

and activate the quota:

```
root@file-server:~# touch /export/home/aquota.user /export/home/aquota.group
root@file-server:~# chmod 600 /export/home/aquota*
root@file-server:~# mount -o remount LABEL=FILES
 
root@file-server:~# quotacheck -avugm
quotacheck: Scanning /dev/mapper/vg_files-lv_files [/export/home] done
quotacheck: Checked 2 directories and 4 files
 
root@file-server:~# quotaon -avug
/dev/mapper/vg_files-lv_files [/export/home]: group quotas turned on
/dev/mapper/vg_files-lv_files [/export/home]: user quotas turned on
 
root@file-server:~/scripts# repquota -a
*** Report for user quotas on device /dev/mapper/vg_files-lv_files
Block grace time: 7days; Inode grace time: 7days
Block limits File limits
User used soft hard grace used soft hard grace
----------------------------------------------------------------------
root -- 36 0 0 4 0 0
```

Next wecreate all the users with home dir under `/export/home`. Then we set the disk quota for each user on that directory to around 4GB:

```
root@file-server:~/scripts# for i in user1 user2 user3 user4 user5; do setquota -u $i 4194304 4194304 0 0 /export/home/; done

root@file-server:~/scripts# repquota -a
*** Report for user quotas on device /dev/mapper/vg_files-lv_files
Block grace time: 7days; Inode grace time: 7days
Block limits File limits
User used soft hard grace used soft hard grace
----------------------------------------------------------------------
root -- 36 0 0 4 0 0
user1 -- 24 4194304 4194304 6 0 0
user2 -- 24 4194304 4194304 6 0 0
user3 -- 24 4194304 4194304 6 0 0
user4 -- 24 4194304 4194304 6 0 0
user5 -- 24 4194304 4194304 6 0 0

### NFS server and exports

We want to export the file system with root enabled to the LDAP server and with root squashed to all the rest in `/etc/exports`:

```
...
/export/home 10.180.16.146(async,rw,no_root_squash,no_subtree_check) *(async,rw,no_subtree_check)
```

Then we can mount the nfs share on the LDAP server:

```
root@ldap-server:~# aptitude install nfs-client
root@ldap-server:~# mount -t nfs 10.180.16.219:/export/home /export/home
```

## NFS Clients

Install the nfs software:

```
$ sudo aptitude install nfs-common
```

Since we are going to use LDAP authentication, we add the following section at the end of the idmapd config file `/etc/idmapd.conf`:

```
[Translation]
 
Method = nsswitch
```

Check if we can see the mounts coming from the NFS server:

```
$ showmount -e 10.180.16.219
Export list for 10.180.16.219:
/export/home *.mydomain.com,10.180.0.0/16,10.180.16.146
```

The NFS setup is now finished and ready.

## Mounting from behind NAT

For the private networks behind NAT to be able to remotely mount the share we need to do some tweaking. First on the server side we enable the access from the NAT servers in the `/etc/exports`:

```
...
/export/home 54.171.xxx.xxx(async,rw,no_subtree_check)
/export/home 54.154.xxx.xxx(async,rw,no_subtree_check)
/export/home 54.66.xxx.xxx(async,rw,no_subtree_check)
```

and reload the service (re-export the shares):

```
root@file-server:~# service nfs-kernel-server reload
 * Re-exporting directories for NFS kernel daemon...   [ OK ]
```

We also open the traffic for TCP and UDP port 2049 in the NFS server SecurityGroup coming from all our NAT/Bastion servers.

Now, on each of our bastion NAT servers we configure port forwarding for the NFSv4 port to the NFS server:

```
root@ip-10-155-0-48:~# iptables -t nat -A PREROUTING -p tcp -s 10.155.0.0/16 --dport 2049 -j DNAT --to-destination 54.79.xxx.xxx.:2049
root@ip-10-155-0-48:~# iptables -t nat -A PREROUTING -p udp -s 10.155.0.0/16 --dport 2049 -j DNAT --to-destination 54.79.xxx.xxx.:2049
root@ip-10-155-0-48:~# iptables -t nat -S
-P PREROUTING ACCEPT
-P INPUT ACCEPT
-P OUTPUT ACCEPT
-P POSTROUTING ACCEPT
-A PREROUTING -s 10.155.0.0/16 -p tcp -m tcp --dport 2049 -j DNAT --to-destination 54.79.xxx.xxx.:2049
-A PREROUTING -s 10.155.0.0/16 -p udp -m udp --dport 2049 -j DNAT --to-destination 54.79.xxx.xxx.:2049
-A POSTROUTING -s 10.155.0.0/16 ! -d 10.155.0.0/16 -o eth0 -j MASQUERADE
```

and save the rules permanently:

```
root@ip-10-155-0-48:~# iptables-save > /etc/iptables/rules.v4
```

On the clients in private EC2 subnets all we need to do is point the client to it's NAT server (10.155.0.48 in this case) when calling the `my-nfs-server.mydomain.com`, in `/etc/hosts`:

```
...
10.155.0.48    my-nfs-server.mydomain.com my-nfs-server
```

and we mount a shared home directory from the NFS server:

```
<my-user>@ip-10-155-0-172:~$ sudo mkdir -p /mnt/home/<my-user>
<my-user>@ip-10-155-0-172:~$ sudo mount -t nfs my-nfs-server.mydomain.com:/export/home/<my-user> /mnt/home/<my-user>
<my-user>@ip-10-155-0-172:~$ cat /proc/mounts | grep my-nfs-server
my-nfs-server.mydomain.com:/export/home/<my-user> /mnt/home/<my-user> nfs4 rw,relatime,vers=4.0,rsize=262144,wsize=262144,namlen=255,hard,proto=tcp,port=0,timeo=600,retrans=2,sec=sys,clientaddr=10.155.0.172,local_lock=none,addr=10.155.0.48 0 0
```

We should do this for the instances launched in public subnets too. With this approach we keep the NFS server name as `my-nfs-server.mydomain.com`, same as set in the LDAP records for the users, and also keep the firewall rules lean since we only have to open the NFS server firewall for handful of hosts instead of tens or even hundreds of clients.

Note that for all private instances in the VPC that have the NAT instance set as default gateway the modification of the `/etc/hosts` file is not needed.

# OpenLDAP setup

We need to install the server and prepare the clients. The LDAP server will hold the user accounts, the home file system `autofs` mappings, the users ssh keys and group associations.

## Server side

The LDAP server will run on an existing Ubuntu-14.04 instance in the same VPC. First we set the NFS server IP in our hosts file just in case of DNS failure:

```
10.180.16.219   my-nfs-server.mydomain.com my-nfs-server
```

### Installation

The LDAP packages and the TLS tools:

```
user@server~$ sudo aptitude install slapd ldap-utils gnutls-bin
```

The Debian/Ubuntu installer will ask some basic questions about the domain we want to setup, in our case `mydomain.com`, the administration user (admin) and the type (bdb or hbd) and the root password for the directory database. This will create the directory file structure under `/etc/ldap/` directory and store the password in `/etc/ldap.secret` file. Since version 2.4 the LDAP configuration has been move from `slapd.conf` file into the database which means it will be available as a DIT it self. By default the system root user will be able to connect to this DIT, with `dn` of `cn=config`, via Unix socket `ldapi:///` connection and `SASL EXTERNAL` authentication method.

Start the service:

```
user@server~$ sudo service slapd start
```

### Setup

The first thing we would like to do is increase the log level so we can debug setup problems. Since the config is now inside LDAP it self as mentioned before, we need to make the changes via LDIF files.

> **LDIF formating**
> The ldap tools like `ldapmodify`, `ldapadd`, `ldapdelete` etc. are very sensitive to the LDIF file formatting especially to blank spaces at the end of the lines!

We create the following `log.ldif` file:

```
log.ldif
dn: cn=config
changetype: modify
add: olcLogLevel
olcLogLevel: stats
```

and apply it by running the above `ldapmodify` command, setting the `rsyslog` and restarting the services:

```
user@server~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f log.ldif
modifying entry "cn=config"
 
user@server~$ sudo echo "com4.*        /var/log/ldap.log" > /etc/rsyslog.d/90-ldap.conf
user@server~$ sudo service rsyslog restart
user@server~$ sudo service slapd restart
```

Next we create an ldif file to create the Company DIT. Run the attached [initial-mydomain-dit.ldif]({{ site.baseurl }}/download/initial-mydomain-dit.ldif) file:

```
user@server:~$ sudo ldapadd -a -H ldapi:/// -f initial-mydomain-dit.ldif -D "cn=admin,dc=mydomain,dc=com" -W
Enter LDAP Password:
adding new entry "ou=Users,dc=mydomain,dc=com"
adding new entry "ou=Groups,dc=mydomain,dc=com"
adding new entry "cn=my-users,ou=Groups,dc=mydomain,dc=com"
adding new entry "ou=Maps,dc=mydomain,dc=com"
```

Then the attached [initial-mydomain-autofs.ldif]({{ site.baseurl }}/download/initial-mydomain-autofs.ldif) file for the autofs mounts:

```
user@server:~$ sudo ldapadd -a -H ldapi:/// -f initial-mydomain-autofs.ldif -D "cn=admin,dc=mydomain,dc=com" -W
Enter LDAP Password:
adding new entry "nisMapName=auto.master,ou=Maps,dc=mydomain,dc=com"
adding new entry "cn=/home,nisMapName=auto.master,ou=Maps,dc=mydomain,dc=com"
adding new entry "nisMapName=auto.home,ou=Maps,dc=mydomain,dc=com"
adding new entry "cn=/,nisMapName=auto.home,ou=Maps,dc=mydomain,dc=com"
```

Next we create our users, their group association and their home mappings by running the attached [initial-mydomain-users.ldif]({{ site.baseurl }}/download/initial-mydomain-users.ldif) file:

```
user@server:~$ ldapadd -a -H ldapi:/// -f initial-mydomain-users.ldif -D "cn=admin,dc=mydomain,dc=com" -W
Enter LDAP Password:
adding new entry "cn=<my-user>,nisMapName=auto.master,ou=Maps,dc=mydomain,dc=com"
adding new entry "uid=<my-user>,ou=Users,dc=mydomain,dc=com"
adding new entry "cn=user1,nisMapName=auto.master,ou=Maps,dc=mydomain,dc=com"
adding new entry "uid=user1,ou=Users,dc=mydomain,dc=com"
adding new entry "cn=user2,nisMapName=auto.master,ou=Maps,dc=mydomain,dc=com"
adding new entry "uid=user2,ou=Users,dc=mydomain,dc=com"
adding new entry "cn=user2,ou=Groups,dc=mydomain,dc=com"
[...]
```

Now we can test the directory to check if the users got created:

```
user@server:~$ sudo ldapsearch -x -LLL -b dc=mydomain,dc=com 'uid=<my-user>' uid uidNumber displayName
dn: uid=<my-user>,ou=Users,dc=mydomain,dc=com
uid: <my-user>
displayName: Name Surname
uidNumber: 12001
```

Next we can create the `my-users` group by running the attached [my-users-group.ldif]({{ site.baseurl }}/download/my-users-group.ldif) file attached as shown before.

To speed up the directory processing we will also create some indices, using the following ldif file `indices.ldif`:

```
dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: uid eq,pres,sub
-
add: olcDbIndex
olcDbIndex: displayName eq,pres,sub
-
add: olcDbIndex
olcDbIndex: objectclass eq
-
add: olcDbIndex
olcDbIndex: cn eq,pres,sub
-
add: olcDbIndex
olcDbIndex: sn eq,pres,sub
-
add: olcDbIndex
olcDbIndex: uidNumber eq
-
add: olcDbIndex
olcDbIndex: gidNumber eq
-
add: olcDbIndex
olcDbIndex: memberUid eq
-
add: olcDbIndex
olcDbIndex: nisMapName eq
```

and execute:


```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f indices.ldif
modifying entry "olcDatabase={1}hdb,cn=config"
```

To finish it off, we need a read-only user we gonna bind with to query the directory from the clients, create the `read-only-user.ldif` file:

```
dn: cn=<my-read-only-user>,ou=Users,dc=mydomain,dc=com
uid: <my-read-only-user>
gecos: Network Service Switch Proxy User
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
userPassword: {SSHA}KW...Zt
shadowLastChange: 15140
shadowMin: 0
shadowMax: 99999
shadowWarning: 7
loginShell: /bin/false
uidNumber: 15001
gidNumber: 15001
homeDirectory: /dev/null
```

and execute:

```
user@server:~$ sudo ldapadd -a -H ldapi:/// -f read-only-user.ldif -D "cn=admin,dc=mydomain,dc=com" -W
Enter LDAP Password:
adding new entry "cn=<my-read-only-user>,ou=Users,dc=mydomain,dc=com"
```

With this the setup of the `mydomain` directory is complete.

### Adding SSH public key support to LDAP

We need to add the following `openssh-lpk-openldap.schema` schema:

```
#
# LDAP Public Key Patch schema for use with openssh-ldappubkey
# useful with PKA-LDAP also
#
# Author: Eric AUGE <eau@phear.org>
#
# Based on the proposal of : Mark Ruijter
#
 
# octetString SYNTAX
attributetype ( 1.3.6.1.4.1.24552.500.1.1.1.13 NAME 'sshPublicKey'
DESC 'MANDATORY: OpenSSH Public key'
EQUALITY octetStringMatch
SYNTAX 1.3.6.1.4.1.1466.115.121.1.40 )
# printableString SYNTAX yes|no
objectclass ( 1.3.6.1.4.1.24552.500.1.1.2.0 NAME 'ldapPublicKey' SUP top AUXILIARY
DESC 'MANDATORY: OpenSSH LPK objectclass'
MUST ( sshPublicKey $ uid )
)
```

To convert this to LDIF format we create intermediate conf file consisting of the core schema and our new one:

```
user@server:~$ mkdir -p ldap
```

add the following in the file `ldap/schema_convert.conf`:

```
include /etc/ldap/schema/core.schema
include /home/user/openssh-lpk-openldap.schema
```

and run the conversion command:

```
user@server:~$ slapcat -f ~/ldap/schema_convert.conf -F ~/ldap -n 0
```

and new conf schema will be created under `~/ldap/` directory and the file we need is `~ldap/cn=config/cn=schema/cn={1}openssh-lpk-openldap.ldif`. By removing the unneeded information we get the final converted LDIF file `openssh-lpk-openldap.ldif`:

```
dn: cn=openssh-openldap,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: openssh-openldap
olcAttributeTypes: {0}( 1.3.6.1.4.1.24552.500.1.1.1.13 NAME 'sshPublicKey' DES
C 'MANDATORY: OpenSSH Public key' EQUALITY octetStringMatch SYNTAX 1.3.6.1.4.
1.1466.115.121.1.40 )
olcObjectClasses: {0}( 1.3.6.1.4.1.24552.500.1.1.2.0 NAME 'ldapPublicKey' DESC
'MANDATORY: OpenSSH LPK objectclass' SUP top AUXILIARY MUST ( sshPublicKey $
uid ) )
```

As before we run the following command to apply the new schema LDIF file:

```
user@server:~$ sudo ldapadd -Q -Y EXTERNAL -H ldapi:/// -f openssh-lpk-openldap.ldif
SASL/EXTERNAL authentication started
SASL username: gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth
SASL SSF: 0
adding new entry "cn=openssh-openldap,cn=schema,cn=config"
```

After we have setup the client for LDAP and login to it with one of our users and it's private key, we can see that the ssh connection using private/public key pair should now work:

```
root@file-server:~# ssh -i /tmp/user1.pem user1@10.180.16.150
```

(where /tmp/user1.pem is the users private key) and we can see the following line in the `/var/log/syslog`:

```
Aug 1 01:32:42 ip-10-180-16-150 sshd[17337]: Loaded 1 SSH public key(s) from LDAP for user: user1
```

### Adding sudo support

Similar to SSH, the SUDO support doesn't come by default with LDAP. We need to use the attached [sudo-openldap.schema]({{ site.baseurl }}/download/sudo-openldap.schema) file and convert it to ldif format as described above. The resulting ldif file is attached [sudo-openldap.ldif]({{ site.baseurl }}/download/sudo-openldap.ldif). We add it:

```
user@server:~$ sudo ldapadd -H ldap:/// -D "cn=admin,cn=config" -W -f sudo-openldap.ldif
ldap_initialize( ldap://:389/??base )
Enter LDAP Password:
add objectClass:
    olcSchemaConfig
add cn:
    sudo-openldap
add olcAttributeTypes:
    {0}( 1.3.6.1.4.1.15953.9.1.1 NAME 'sudoUser' DESC 'User(s) who may  run sudo' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
    {1}( 1.3.6.1.4.1.15953.9.1.2 NAME 'sudoHost' DESC 'Host(s) who may run sudo' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
    {2}( 1.3.6.1.4.1.15953.9.1.3 NAME 'sudoCommand' DESC 'Command(s) to be executed by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
    {3}( 1.3.6.1.4.1.15953.9.1.4 NAME 'sudoRunAs' DESC 'User(s) impersonated by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
    {4}( 1.3.6.1.4.1.15953.9.1.5 NAME 'sudoOption' DESC 'Options(s) followed by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
    {5}( 1.3.6.1.4.1.15953.9.1.6 NAME 'sudoRunAsUser' DESC 'User(s) impersonated by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
    {6}( 1.3.6.1.4.1.15953.9.1.7 NAME 'sudoRunAsGroup' DESC 'Group(s) impersonated by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
    {7}( 1.3.6.1.4.1.15953.9.1.8 NAME 'sudoNotBefore' DESC 'Start of time interval for which the entry is valid' EQUALITY generalizedTimeMatch ORDERING generalizedTimeOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.24 )
    {8}( 1.3.6.1.4.1.15953.9.1.9 NAME 'sudoNotAfter' DESC 'End of time interval for which the entry is valid' EQUALITY generalizedTimeMatch ORDERING generalizedTimeOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.24 )
    {9}( 1.3.6.1.4.1.15953.9.1.10 NAME 'sudoOrder' DESC 'an integer to order the sudoRole entries' EQUALITY integerMatch ORDERING integerOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.27 )
add olcObjectClasses:
    {0}( 1.3.6.1.4.1.15953.9.2.1 NAME 'sudoRole' DESC 'Sudoer Entries' SUP top STRUCTURAL MUST cn MAY ( sudoUser $ sudoHost $ sudoCommand $ sudoRunAs $ sudoRunAsUser $ sudoRunAsGroup $ sudoOption $ sudoNotBefore $ sudoNotAfter $ sudoOrder $ description ) )
adding new entry "cn=sudo-openldap,cn=schema,cn=config"
modify complete
```

Next we create the SUDOers object in the DIT we gonna use for the `sudoers` group, the ldif attached as [sudo.ldif]({{ site.baseurl }}/download/sudo.ldif) file:

```
user@server:~$ sudo ldapadd -v -H ldapi:/// -D "cn=admin,dc=mydomain,dc=com" -W -f sudo.ldif
ldap_initialize( ldapi:///??base )
Enter LDAP Password:
add objectClass:
    top
    sudoRole
add cn:
    defaults
add description:
    Default sudoOption's go here
add sudoOption:
    env_keep+=SSH_AUTH_SOCK
adding new entry "cn=defaults,ou=SUDOers,dc=mydomain,dc=com"
modify complete
add objectClass:
    top
    sudoRole
add cn:
    %my-users
add sudoUser:
    %my-users
add sudoHost:
    ALL
add sudoCommand:
    ALL
adding new entry "cn=%my-users,ou=SUDOers,dc=mydomain,dc=com"
modify complete
```

At the end on the server we can see the following schemas activated:

```
user@server:~$ sudo ldapsearch -x -H ldap:/// -LLL -D "cn=admin,cn=config" -W -b "cn=schema,cn=config" dn
Enter LDAP Password:
dn: cn=schema,cn=config
dn: cn={0}core,cn=schema,cn=config
dn: cn={1}cosine,cn=schema,cn=config
dn: cn={2}nis,cn=schema,cn=config
dn: cn={3}inetorgperson,cn=schema,cn=config
dn: cn={4}openssh-openldap,cn=schema,cn=config
dn: cn={5}sudo-openldap,cn=schema,cn=config
```

We also index the new dn, create `sudo-index.ldif` file:

```
dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: sudoUser eq
-
add: olcDbIndex
olcDbIndex: sudoHost eq
```

and run the following command:

```
user@server:~$ sudo ldapmodify -v -H ldapi:/// -D "cn=admin,cn=config" -W -f sudo-index.ldif -Z
ldap_initialize( ldapi:///??base )
Enter LDAP Password:
add olcDbIndex:
sudoUser eq
add olcDbIndex:
sudoHost eq
modifying entry "olcDatabase={1}hdb,cn=config"
modify complet
```

### Adding TLS/SSL support

We start by installing some packages and adding the ldap user to the certificates group:

```
user@server:~$ sudo aptitude install gnutls-bin ssl-cert
user@server:~$ sudo usermod -a -G ssl-cert openldap
```

Since we already have a signed certificate by a CA authority we can use that one. Place the certs and the private key:

```
user@server:~$ sudo cp star_mydomain_com.pem /etc/ssl/certs/
user@server:~$ sudo cp DigiCertCA.crt /etc/ssl/certs/
user@server:~$ sudo cp contentCaKey.pem /etc/ssl/private/
user@server:~$ sudo chgrp ssl-cert /etc/ssl/private/contentCaKey.pem
user@server:~$ sudo chmod 640 /etc/ssl/private/contentCaKey.pem
user@server:~$ sudo ln -sf /etc/ssl/certs/star_mydomain_com.pem /etc/ssl/certs/$(openssl x509 -in /etc/ssl/certs/star_mydomain_com.pem -noout -hash).0
user@server:~$ sudo ln -sf /etc/ssl/certs/DigiCertCA.crt /etc/ssl/certs/$(openssl x509 -in /etc/ssl/certs/DigiCertCA.crt -noout -hash).0
```

To confirm the certificate is alright:

```
user@server:~$ openssl verify -purpose sslserver -CAfile /etc/ssl/certs/DigiCertCA.crt /etc/ssl/certs/star_mydomain_com.pem
/etc/ssl/certs/star_mydomain_com.pem: OK
```

Then we run the attached [ssl.ldif]({{ site.baseurl }}/download/ssl.ldif) file to tell the server where to find the certificate(s) and then the `force-tls.ldif` file:

```
dn: olcDatabase={1}hdb,cn=config
changetype:  modify
add: olcSecurity
olcSecurity: tls=1
```

to force all client communication go encrypted.

```
user@server:~$ sudo ldapmodify -H ldap:/// -f force-tls.ldif -D "cn=admin,cn=config" -W
Enter LDAP Password:
modifying entry "olcDatabase={1}hdb,cn=config"
```

Now if we check from the client side we will see:

```
<my-user>@ip-10-180-16-150:~$ ldapsearch -x -H ldap://my-ldap-server.mydomain.com:389/ -b dc=mydomain,dc=com "(uid=user1)"
# extended LDIF
#
# LDAPv3
# base <dc=mydomain,dc=com> with scope subtree
# filter: (uid=user1)
# requesting: ALL
#
# search result
search: 2
result: 13 Confidentiality required
text: TLS confidentiality required
# numResponses: 1
```

Good, it is asking for TLS connection not allowing plain one.

### ACL's and security

#### Disable anonymous access

We need to disable the anonymous access for security reasons by running the attached [acl.ldif]({{ site.baseurl }}/download/acl.ldif) file (we don't want the whole world to have read access our sensitive data):

```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f acl.ldif
```

This will force authentication for the anonymous user and give read access to our read-only <my-read-only-user> user we gonna use to bind to the directory from all our clients.

#### Create additional admin user

We will also create additional admin user for the config database we can bind with so we don't have to be limited to `ldapi:///` socket only and the `EXTERNAL SASL` authentication, the below file is also attached as [config-admin-user.ldif]({{ site.baseurl }}/download/config-admin-user.ldif). First we create encrypted password:

```
user@server:~$ slappasswd -h {SSHA} -s <myadmin-password>
{SSHA}TmiafWO99PpLBtPZRPqEMRiLa2AlGO9K
```

and use it in the `config_admin_user.ldif` file and apply the changes:

```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f config_admin_user.ldif
modifying entry "cn=config"
modifying entry "olcDatabase={0}config,cn=config"
modifying entry "olcDatabase={0}config,cn=config"
modifying entry "olcDatabase={0}config,cn=config"
```

Now, we don't have to use EXTERNAL access only as root:

```
user@server:~$ sudo ldapsearch -H ldap:/// -D "cn=admin,cn=config" -W -b "" -LLL -s base supportedSASLMechanisms
Enter LDAP Password:
dn:
supportedSASLMechanisms: GS2-IAKERB
supportedSASLMechanisms: GS2-KRB5
supportedSASLMechanisms: SCRAM-SHA-1
supportedSASLMechanisms: GSSAPI
supportedSASLMechanisms: DIGEST-MD5
supportedSASLMechanisms: CRAM-MD5
supportedSASLMechanisms: NTLM
```

At the end it is a good idea to check the configuration for any errors:

```
user@server:~$ sudo slaptest -uF /etc/ldap/slapd.d
config file testing succeeded
```

### Logrotate

Slapd uses rsyslog for its logging to its `/var/log/ldap.log` log file. To manage the log size and history we can use the following Logrotate `/etc/logrotate/ldap` file:

```
/var/log/ldap.log {
    su root syslog
    daily
    rotate 7
    size 100M
    missingok
    notifempty
    compress
    create 640 syslog adm
    sharedscripts
    postrotate
      # OpenLDAP logs via syslog, restart syslog if running
      restart rsyslog
    endscript
}
```

To test the script and confirm it will run properly:

```
user@server:~$ sudo logrotate -df /etc/logrotate.d/ldap
```
 
## Client side

I have launched a test `t1.micro` instance (10.180.16.150) of Ubuntu-14.04 to take the role of a client. As usual Debian/Ubuntu offers some basic configuration through the package installation which sets up the LDAP profile for `NSS` and `PAM`:

```
user@ip-10-180-16-150:~$ sudo aptitude install libnss-ldap libpam-ldap nscd autofs autofs-ldap rpcbind nfs-client ldap-utils
user@ip-10-180-16-150:~$ sudo dpkg-reconfigure ldap-auth-config
user@ip-10-180-16-150:~$ sudo auth-client-config -t nss -p lac_ldap
user@ip-10-180-16-150:~$ sudo pam-auth-update
```

After answering the question about the LDAP server connection (ldap://my-ldap-server.mydomain.com:389/), the user to bind with (cn=<my-read-only-user>,dc=mydomain,dc=com) and its password we should see the following in the `/etc/ldap.conf` file:

```
...
base dc=mydomain,dc=com
uri ldap://10.180.16.146:389/
ldap_version 3
rootbinddn cn=<my-read-only-user>,dc=mydomain,dc=com
pam_password md5
ssl start_tls
tls_checkpeer yes
tls_cacertdir /etc/ssl/certs
nss_initgroups_ignoreusers backup,bin,daemon,games,gnats,irc,landscape,libuuid,list,lp,mail,man,messagebus,news,nslcd,pollinate,proxy,root,sshd,statd,sync,sys,syslog,uucp,www-data
```

We have set some tls options in the above file as well since they are needed for our connection to the server that has been setup to always ask for `STARTTLS`.

In the LDAP client configuration file `/etc/ldap/ldap.conf` we set the LDAP parameters and the TLS connection:

```
BASE            dc=mydomain,dc=com
BINDDN          cn=<my-read-only-user>,ou=Users,dc=mydomain,dc=com
BINDPW          <my-read-only-password>
URI             ldap://my-ldap-server.mydomain.com
TLS_REQCERT     never  
TLS_CACERT      /etc/ssl/certs/ca-certificates.crt
SSL             off
SSL             start_tls
```

Also the following PAM files `/etc/pam.d/common-password` should have the following lines added for us:

```
...
#password   [success=1 user_unknown=ignore default=die]     pam_ldap.so use_authtok try_first_pass
password    [success=1 user_unknown=ignore default=die]     pam_ldap.so try_first_pass
... 
```

We modify this line as shown above so the users could be able to change passwords on the OpenLDAP Server, using the `passwd` command, we must remove `use_authtok` from `/etc/pam.d/common-password` since `use_authtok` disables the password prompt.

* /etc/pam.d/common-auth

```
...
auth    [success=1 default=ignore]  pam_ldap.so use_first_pass
...
```

* /etc/pam.d/common-session

```
...
session optional            pam_ldap.so
...
```

* /etc/pam.d/common-account

```
...
account [success=1 default=ignore]  pam_ldap.so
...
```

* /etc/pam.d/common-session-noninteractive

```
...
session optional            pam_ldap.so
...
```

The position of the lines in those files is important too.

Some other files we need to check and setup are:

* for autofs (/etc/default/autofs and /etc/autofs_ldap_auth.conf)
* for nss (/etc/nsswitch.conf)
* for sudo (/etc/sudo-ldap.conf)

 
The `/etc/nsswitch.conf` file:

```
#passwd:         ldap compat
#group:          ldap compat
#shadow:         ldap compat
passwd:         files ldap
group:          files ldap
shadow:         files ldap
 
hosts:          files dns
networks:       files
 
protocols:      db files
services:       db files
ethers:         db files
rpc:            db files
 
netgroup:       nis
 
automount:      ldap files
sudoers:        ldap files
```

We add `automount` and `sudoers` lines in the above file since this functionality will come from LDAP too. The users home directories will be NFS mounted via LDAP.

We set the following lines in the autofs `/etc/default/autofs` config files:

```
MASTER_MAP_NAME="/etc/auto.master"
TIMEOUT=300
BROWSE_MODE="no"
LOGGING="debug"
LDAP_URI="ldap://my-ldap-server.mydomain.com:389/"
SEARCH_BASE="ou=Maps,dc=mydomain,dc=com"
MAP_OBJECT_CLASS="nisMap"
ENTRY_OBJECT_CLASS="nisObject"
MAP_ATTRIBUTE="nisMapName"
ENTRY_ATTRIBUTE="cn"
VALUE_ATTRIBUTE="nisMapEntry"
```

and the autofs authentication file `/etc/autofs_ldap_auth.conf` (we use our read-only <my-read-only-user> user for simple bind via TLS):

```
<?xml version="1.0" ?>
<!--
This files contains a single entry with multiple attributes tied to it.
See autofs_ldap_auth.conf(5) for more information.
-->
<autofs_ldap_sasl_conf
        usetls="yes"
        tlsrequired="yes"
        authrequired="simple"
        user="cn=<my-read-only-user>,ou=Users,dc=mydomain,dc=com"
        secret="<my-read-only-password>"
/>
```

We set the permissions so only the root user can read:

```
user@ip-10-180-16-150:~$ sudo chmod 600 /etc/autofs_ldap_auth.conf
```

and restart the service:

```
user@ip-10-180-16-150:~$ sudo service autofs restart
```

Add the DNS entries for our LDAP and NFS server so the client can resolve them:

```
10.180.16.146 my-ldap-server.mydomain.com my-ldap-server
10.180.16.219 my-nfs-server.mydomain.com my-nfs-server
```

To enable the `sudo` privileges for `my-users` group from LDAP we need to install the `sudo-ldap` package to replace the default sudo and set its configuration file:

```
user@ip-10-180-16-150:~$ sudo export SUDO_FORCE_REMOVE=yes
user@ip-10-180-16-150:~$ sudo dpkg -P sudo
user@ip-10-180-16-150:~$ sudo aptitude install sudo-ldap
user@ip-10-180-16-150:~$ sudo export SUDO_FORCE_REMOVE=no
```

Then we set the following in the `/etc/sudo-ldap.conf` config file:

```
BASE            dc=mydomain,dc=com
SUDOERS_BASE    ou=SUDOers,dc=mydomain,dc=com
BINDDN          cn=<my-read-only-user>,ou=Users,dc=mydomain,dc=com
BINDPW          <my-read-only-password>
ROOTBINDDN      cn=admin,dc=mydomain,dc=com
URI             ldap://my-ldap-server.mydomain.com
TLS_CHECKPEER   on
TLS_CACERT      /etc/ssl/certs/ca-certificates.crt
SSL             off
SSL             start_tls
```

Next step is to enable the client to use the ssh public key stored in the directory for the users password-less authentication. On Ubuntu-14.04 the sshd already comes with this functionality but for Ubuntu-12.04 we need a patched version of `openssh`. Luckily a ppa repo already exists:

```
$ sudo add-apt-repository ppa:nicholas-hatch/auth
$ sudo aptitude update
$ sudo aptitude safe-upgrade
```

Then we need the `ssh-ldap-pubkey-wrapper` installed (see https://pypi.python.org/pypi/ssh-ldap-pubkey/0.2.2):

```
user@ip-10-180-16-150:~$ sudo aptitude install gnutls-bin ssl-cert
user@ip-10-180-16-150:~$ sudo aptitude install python-pip python-dev libldap2-dev sasl2-bin libsasl2-dev
user@ip-10-180-16-150:~$ sudo pip install ssh-ldap-pubkey
user@ip-10-180-16-150:~$ ln -s /usr/local/bin/ssh-ldap-pubkey /usr/bin/ssh-ldap-pubkey
user@ip-10-180-16-150:~$ ln -s /usr/local/bin/ssh-ldap-pubkey-wrapper /usr/bin/ssh-ldap-pubkey-wrapper
user@ip-10-180-16-150:~$ sudo ldconfig
```

To confirm the wrapper is operational we run (we should get the public ssh key for the user in the output):

```
user@ip-10-180-16-150:~$ ssh-ldap-pubkey-wrapper <my-user> -f /etc/ldap.conf -w -d
ssh-rsa AAAAB3N...KG/UrSGm7 <my-user>@host
```

so it works. We can also use this wrapper to modify the `sshKey` attribute in the users records, for example:

```
<my-user>@ip-10-180-16-150:~$ ssh-ldap-pubkey add ~/.ssh/id_rsa.pub
```

will add the current users public key in its LDAP record. To target different user:

```
<my-user>@ip-10-180-16-150:~$ ssh-ldap-pubkey -u user1 add ~/.ssh/user1_id_rsa.pub
```

Now we can add:

```
...
AuthorizedKeysCommand /usr/local/bin/ssh-ldap-pubkey-wrapper
AuthorizedKeysCommandUser nobody
...
```

to `/etc/ssh/sshd_config` file and reload ssh daemon:

```
<my-user>@ip-10-180-16-150:~$ sudo service ssh reload
```

That's it, now any of our users can login to the client EC2 instance using the public keys stored in the directory and get its privileges, user and group id, sudo access and its home directory mounted via LDAP and NFS upon login:

```
root@ip-10-180-16-150:~# cat /proc/mounts | grep nfs
my-nfs-server.mydomain.com:/export/home/<my-user> /home/<my-user> nfs4 rw,relatime,vers=4.0,rsize=262144,wsize=262144,namlen=255,hard,proto=tcp,port=0,timeo=600,retrans=2,sec=sys,clientaddr=10.180.16.150,local_lock=none,addr=10.180.16.219 0 0
 
root@ip-10-180-16-150:~# nfsstat -m
/home/<my-user> from my-nfs-server.mydomain.com:/export/home/<my-user>
 Flags:    rw,relatime,vers=4.0,rsize=262144,wsize=262144,namlen=255,hard,proto=tcp,port=0,timeo=600,retrans=2,sec=sys,clientaddr=10.180.16.150,local_lock=none,addr=10.180.16.219
```

## High Availability

This part is covered in the [LDAP replication for Directory High-Availability]({{ site.baseurl }}{% post_url 2014-8-18-LDAP-replication-for-Directory-HA %}) page.
