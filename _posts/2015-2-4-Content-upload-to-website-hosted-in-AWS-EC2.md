---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Content upload to Joomla! website hosted in AWS EC2'
categories: 
  - Webserver
tags: [vsftpd,high-availability]
date: 2015-2-4
---

We have a Joomla! website hosted by clustered services on couple of EC2 instances. The document root resides on shared storage provided by GlusterFS. We need to enable multiple users to upload and change the content in the document root directory. In these cases the main problem we need to solve is the file permissions. One hacky option I have found is utilizing a LInux feature that allows creation of multiple users with the same user id. Since the documents have owner permissions of the `www-data` user:  

```
root@ip-172-31-19-153:~# id -a www-data 
uid=33(www-data) gid=33(www-data) groups=33(www-data),4(adm)
```

all I need to do is create every new user with the same `uid` and `gid` as this user. These users will be used for content upload only so no issues related to the usage of same uid/gid is expected in this case.

Next we need to decide what are we going to use for uploading the content. I want a secure, encrypted user authentication and content upload so I'll be using `Vsftpd` as ftp server in this case:

```
$ sudo aptitude install vsftpd whois libstring-mkpasswd-perl
```

Now we can create our first user given below as `Username`. Create secure `sha512` user password as standard for Ubuntu/Debian (the password below is not the password used on the servers of course):

```
$ mkpasswd.pl -l 12
4tsXmn*o2Otb

$ mkpasswd -m sha-512 4tsXmn*o2Otb
$6$TzZ9dsJeiqhUk.$StyBpwqul2Zs0ZCBBcjav/iUdaiCtiw9te/JQcFdDUSKUNjVVdmS3bXjg/ewgH7d/AjMw/ULw8o67S5mD1Ijc.
```

Create the user, add record to `/etc/passwd` file:

```
Username:x:33:33:Username ftp user:/var/www/html:/usr/sbin/nologin
```

and shadow record too in `/etc/shadow`:

```
Username:$6$TzZ9dsJeiqhUk.$StyBpwqul2Zs0ZCBBcjav/iUdaiCtiw9te/JQcFdDUSKUNjVVdmS3bXjg/ewgH7d/AjMw/ULw8o67S5mD1Ijc.:16485:0:99999:7:::
```

Repeat the procedure for each user we need to create. Notice that the user(s) has the document root `/var/www/html` set as home directory and has no available shell set for security reasons.

Backup and modify the `/etc/vfstpd.conf` on both servers:

```
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=0033
file_open_mode=0777
dirmessage_enable=YES
chown_uploads=NO
ftpd_banner=Joomla content upload FTP service.
listen=YES
tcp_wrappers=YES

allow_writeable_chroot=YES
connect_from_port_20=YES
force_dot_files=YES
hide_ids=YES
max_clients=20
max_per_ip=20

### User access and authentication ###
pam_service_name=ftp
userlist_file=/etc/vsftpd.userlist
userlist_enable=YES
userlist_deny=NO
# all users are jailed by default
chroot_local_user=YES
chroot_list_enable=NO

### Logging ###
dual_log_enable=YES
xferlog_enable=YES
xferlog_std_format=YES
log_ftp_protocol=YES

### Passive mode ###
pasv_enable=YES
pasv_min_port=12200
pasv_max_port=12250
port_enable=YES
pasv_address=54.xx.xx.xx
pasv_addr_resolve=NO
#pasv_address=ip-172-31-19-153.eu-west-1.compute.internal
#pasv_addr_resolve=YES

### Secure connections ###
ssl_enable=YES
ssl_ciphers=HIGH
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
require_ssl_reuse=NO
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
rsa_cert_file=/etc/ssl/certs/vsftpd.pem
```

For the second server we just need to replace the VIP in the `pasv_address` field. The DNS is managed via `Route53` with health-checks and the document root is on a shared storage as mentioned before so really doesn't matter which host the user connects to.

The above configuration provides us with the following:

* Users login via SSL only and only using TLSv1 cipher suits
* Each user is jailed in `/var/www/html` upon login
* Only the users specified in the `/etc/vsftpd.userlist` are allowed to login
* We enable passive FTP mode on bunch of specific ports

Now we need to add the user to the allowed users ftp file we specified in the above configuration:

```
$ sudo echo Username > /etc/vsftpd.userlist
```

And finally open the `SecurityGroup` firewall for the FTP server and the passive mode ports:

```
$ aws ec2 authorize-security-group-ingress --group-id sg-42xxxxxx --ip-protocol tcp --from-port 20 --to-port 21 --cidr-ip 0.0.0.0/0
$ aws ec2 authorize-security-group-ingress --group-id sg-42xxxxxx --ip-protocol tcp --from-port 12200 --to-port 12250 --cidr-ip 0.0.0.0/0
```

Since this user will have access to the Joomla root we need to protect some pages and the administrator directory bit more:

```
$ cd /var/www/html
$ sudo usermod -a -G adm www-data
$ sudo chown -R root:adm administrator/
$ sudo find administrator/ -name \* -type d -exec chmod 0775 {} \;
$ sudo find administrator/ -name \* -type f -exec chmod 0664 {} \;
$ sudo chown root\: .htaccess info.php google879aeaf49c839581.html robots.txt
```

Now the user `Username` can connect to the site via FTP client like Filezilla lets say using encrypted TLS connection.