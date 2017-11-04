---
type: posts
header:
  teaser: 'Device-Mesh.jpg'
title: 'LDAP replication for Directory High-Availability'
categories: 
  - DevOps
tags: [ldap, nfs, aws]
date: 2014-8-18
---

As said before, once the users and services rely on the LDAP server for providing credentials and permissions the LDAP server becomes crucial part of any setup. Thus providing HA for our existing Master is of high importance.

This page is the final part of the Unified Linux Login, Privileges and Home Directory Using OpenLDAP and NFS/automount article.

# LDAP Replication

We will setup a refreshAndPersist replication using the `delta-syncrepl` replication scheme. In its `refreshAndPersist` mode of synchronization, the provider uses a push-based synchronization. The provider keeps track of the consumer servers that have requested a persistent search and sends them necessary updates as the provider replication content gets modified. Since we are using delta-syncrepl the provider will only send the changes to the consumer servers and not the whole DIT thus reducing the overhead and the network traffic.

## Provider Setup

Setting up delta-syncrepl requires configuration changes on both the master (i.e. provider) and replica (i.e. consumer) servers. We will start by configuring the provider machine (in our case my-ldap-server.mydomain.com) and then continue to the consumer machine.

First we need the the dn of the module configuration:

```
user@server:~$ sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=config dn | grep module
dn: cn=module{0},cn=config
```

So we can find/confirm the Modules path:

```
user@server:~$ sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=module{0},cn=config
dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module{0}
olcModulePath: /usr/lib/ldap
olcModuleLoad: {0}back_hdb
```

We can check for available modules in the modules directory:

```
user@server:~$ ls -l /usr/lib/ldap/*.la
```

We need to activate two additional modules we need for the replication so we create `module.ldif` ldif file to add them:

```
# Add the replication modules
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: {1}accesslog.la
olcModuleLoad: {2}syncprov.la

and apply the config:
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f module.ldif
modifying entry "cn=module{0},cn=config"
```

We can confirm they have been activated:

```
user@server:~$ sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=module{0},cn=config
 
dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module{0}
olcModulePath: /usr/lib/ldap
olcModuleLoad: {0}syncprov.la
olcModuleLoad: {1}accesslog.la
olcModuleLoad: {2}back_hdb
```

Now that we have the `accesslog` overlay module loaded, we must create a database in which to store the accesslog data. We of course do this with another LDIF file but we first create the directory for our new data base:

```
user@server:~$ sudo mkdir -p /var/lib/ldap/accesslog
user@server:~$ sudo cp /var/lib/ldap/DB_CONFIG /var/lib/ldap/accesslog/
user@server:~$ chown -R openldap\: /var/lib/ldap/accesslog
```

then the `accesslog.ldif` ldif:

```
# Configure the accesslog database
dn: olcDatabase=hdb,cn=config
changetype: add
objectClass: olcDatabaseConfig
objectClass: olcHdbConfig
olcDatabase: hdb
olcDbDirectory: /var/lib/ldap
olcSuffix: cn=accesslog
olcRootDN: cn=admin,dc=mydomain,dc=com
olcDbIndex: default eq
olcDbIndex: entryCSN,objectClass,reqEnd,reqResult,reqStart
```

execute the file:

```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f accesslog.ldif
adding new entry "olcDatabase=hdb,cn=config"
```

Confirm the creation:

```
user@server:~$ sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b olcDatabase={2}hdb,cn=config
 
dn: olcDatabase={2}hdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcHdbConfig
olcDatabase: {2}hdb
olcDbDirectory: /var/lib/ldap/accesslog
olcSuffix: cn=accesslog
olcRootDN: cn=admin,dc=mydomain,dc=com
olcDbIndex: default eq
olcDbIndex: entryCSN,objectClass,reqEnd,reqResult,reqStart
```

### Provider Syncprov Overlay Over the Accesslog Database

Next we setup a `syncprov` overlay on the new accesslog database. Create this `overlay-accesslog.ldif` LDIF file:

```
# Add an overlay on the cn=accesslog database.
dn: olcOverlay=syncprov,olcDatabase={2}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpNoPresent: TRUE
olcSpReloadHint: TRUE
```

and execute:

```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f overlay-accesslog.ldif
adding new entry "olcOverlay=syncprov,olcDatabase={2}hdb,cn=config"
```

Check it out:

```
user@server:~$ sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b olcDatabase={2}hdb,cn=config
 
dn: olcDatabase={2}hdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcHdbConfig
olcDatabase: {2}hdb
olcDbDirectory: /var/lib/ldap
olcSuffix: cn=accesslog
olcRootDN: cn=admin,dc=mydomain,dc=com
olcDbIndex: default eq
olcDbIndex: entryCSN,objectClass,reqEnd,reqResult,reqStart
dn: olcOverlay={0}syncprov,olcDatabase={2}hdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: {0}syncprov
olcSpNoPresent: TRUE
olcSpReloadHint: TRUE
```

### Provider Overlays On Primary Database

Do do this objective, we must of course write another LDIF file in which we will:

* setup new indexes to our primary database
* add the syncprov overlay
* add the accesslog overlay

The `overlay-primary.ldif` ldif first:

```
# Add new indexes to the primary database.
dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: entryCSN eq
-
add: olcDbIndex
olcDbIndex: entryUUID eq
# Add the syncprov overlay on the dc=mydomain,dc=com database.
dn: olcOverlay=syncprov,olcDatabase={1}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckPoint: 500 15
# Add the accesslog overlay on the dc=mydomain,dc=com database.
# scan the accesslog DB every day, and purge entries older than 7 days
dn: olcOverlay=accesslog,olcDatabase={1}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcAccessLogConfig
olcOverlay: accesslog
olcAccessLogDB: cn=accesslog
olcAccessLogOps: writes
olcAccessLogPurge: 7+00:00 1+00:00
olcAccessLogSuccess: TRUE
```

execute the file:

```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f overlay-primary.ldif
modifying entry "olcDatabase={1}hdb,cn=config"
adding new entry "olcOverlay=syncprov,olcDatabase={1}hdb,cn=config"
adding new entry "olcOverlay=accesslog,olcDatabase={1}hdb,cn=config"
```

Confirm the overlays have been created:

```
user@server:~$ sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b olcDatabase={1}hdb,cn=config dn
 
dn: olcDatabase={1}hdb,cn=config
dn: olcOverlay={0}syncprov,olcDatabase={1}hdb,cn=config
dn: olcOverlay={1}accesslog,olcDatabase={1}hdb,cn=config
```

### Provider Replication User

We need a user for the replication. That user will be used to authenticate the replication server and read the data and nothing else. Once again, we need an LDIF file `replication.ldif`.

```
# Create the replication user
dn: cn=replication,dc=mydomain,dc=com
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replication
description: OpenLDAP Replication User
userPassword: 3nc0mpass25$
```

execution:

```
user@server:~$ sudo ldapadd -a -H ldapi:/// -f replication.ldif -D "cn=admin,dc=mydomain,dc=com" -W
Enter LDAP Password:
adding new entry "cn=replication,dc=mydomain,dc=com"
```

### Provider Limits and ACLs to the Replication User

We now need to give access via ACLs and some limits to the new user. We do it in two steps starting with the limits `limits.ldif`:

```
# Add limits to the cn=accesslog database.
dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcLimits
olcLimits: dn.exact="cn=replication,dc=mydomain,dc=com" time.soft=unlimited time.hard=unlimited size.soft=unlimited size.hard=unlimited
 
# Add limits to the dc=mydomain,dc=com database.
dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcLimits
olcLimits: dn.exact="cn=replication,dc=mydomain,dc=com" time.soft=unlimited time.hard=unlimited size.soft=unlimited size.hard=unlimited
```

execute the file:

```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f limits.ldif
 
modifying entry "olcDatabase={2}hdb,cn=config"
modifying entry "olcDatabase={1}hdb,cn=config"
```

Modify the ACL's for our new user for both databases, the DIT and the accesslog `acl.ldif`:

```
dn: olcDatabase={1}hdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange by dn="cn=admin,dc=mydomain,dc=com" write by self write by anonymous auth by * none
olcAccess: {1}to dn.base="" by anonymous auth by * none
olcAccess: {2}to * by dn="cn=admin,dc=mydomain,dc=com" write by dn="cn=my-readonly-user,ou=Users,dc=mydomain,dc=com" read by dn="cn=replication,dc=mydomain,dc=com" read by anonymous auth by * none
 
dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {0}to * by dn="cn=admin,dc=mydomain,dc=com" write by dn="cn=replication,dc=mydomain,dc=com" read by anonymous auth by * none
```

run it and confirm the changes:

```
user@server:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f acl.ldif
user@server:~$ sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b olcDatabase={1}hdb,cn=config olcAccess
 
dn: olcDatabase={1}hdb,cn=config
olcAccess: {0}to attrs=userPassword,shadowLastChange by dn="cn=admin,dc=encomp
asshost,dc=com" write by self write by anonymous auth by * none
olcAccess: {1}to dn.base="" by anonymous auth by * none
olcAccess: {2}to * by dn="cn=admin,dc=mydomain,dc=com" write by dn="cn=ns
sproxy,ou=Users,dc=mydomain,dc=com" read by dn="cn=replication,dc=encomp
asshost,dc=com" read by anonymous auth by * none
```

That's it our provider has been setup.

## Consumer Setup

We launch the replica server on t1.micro instance in the second AZ so we have HA.

```
user@replica:~$ sudo aptitude install slapd ldap-utils
user@replica:~$ sudo dpkg-reconfigure slapd
```

First we need to add the sudo and ssh schema's same as on the provider:

```
user@replica:~$ sudo ldapadd -Q -Y EXTERNAL -H ldapi:/// -f sudo-openldap.ldif
user@replica:~$ sudo ldapadd -Q -Y EXTERNAL -H ldapi:/// -f openssh-lpk-openldap.ldif
```

Then the consumer sync ldif `consumer-sync.ldif`:

```
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov
dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: entryUUID eq
-
add: olcSyncRepl
olcSyncRepl: rid=0 provider=ldap://my-ldap-server.mydomain.com bindmethod=simple binddn="cn=replication,dc=mydomain,dc=com"
credentials=3nc0mpass25$ searchbase="dc=mydomain,dc=com" logbase="cn=accesslog"
logfilter="(&(objectClass=auditWriteObject)(reqResult=0))" schemachecking=on
type=refreshAndPersist retry="60 +" syncdata=accesslog
-
add: olcUpdateRef
olcUpdateRef: ldap://my-ldap-server.mydomain.com
```

execute it:

```
user@replica:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f consumer-sync.ldif
 
modifying entry "cn=module{0},cn=config"
modifying entry "olcDatabase={1}hdb,cn=config"
```

Set the certs as on the provider side and add TLS support to the LDAP:

```
user@replica:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f ssl.ldif
 
modifying entry "cn=config"
```

After enabling TLS we should include the TLS settings in the replication as well so the data is not being transferred in clear text:

```
# consumer-sync-tls.ldif
dn: olcDatabase={1}hdb,cn=config
replace: olcSyncRepl
olcSyncRepl: rid=0 provider=ldap://my-ldap-server.mydomain.com bindmethod=simple binddn="cn=replication,dc=mydomain,dc=com"
credentials=3nc0mpass25$ searchbase="dc=mydomain,dc=com" logbase="cn=accesslog"
logfilter="(&(objectClass=auditWriteObject)(reqResult=0))" schemachecking=on
type=refreshAndPersist retry="60 +" syncdata=accesslog
starttls=critical tls_reqcert=demand
```

apply the changes:

```
user@replica:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f consumer-sync-tls.ldif
 
modifying entry "olcDatabase={1}hdb,cn=config"
```

We might also set the client config file `/etc/ldap/ldap.conf` just to make easier for applications to connect to the master:

```
BASE dc=mydomain,dc=com
URI ldap://my-ldap-server.mydomain.com
TLS_CACERT /etc/ssl/certs/DigiCertCA.crt
TLS_REQCERT allow
TIMELIMIT 15
TIMEOUT 20
```

Also we modify the ACL's so the clients can use `my-readonly-user` user to bind to the replica too:

```
# acl.ldif
dn: olcDatabase={1}hdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange by dn="cn=admin,dc=mydomain,dc=com" write by self write by anonymous auth by * none
olcAccess: {1}to dn.base="" by anonymous auth by * none
olcAccess: {2}to * by dn="cn=admin,dc=mydomain,dc=com" write by dn="cn=my-readonly-user,ou=Users,dc=mydomain,dc=com" read by anonymous auth by * none
```

apply the changes:

```
user@replica:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f acl.ldif
```

And we set the indices as well so the searches are more effective:

```
# indices.ldif
dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: uid eq,pres,sub
-
add: olcDbIndex
olcDbIndex: displayName eq,pres,sub
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
olcDbIndex: sudoUser eq
-
add: olcDbIndex
olcDbIndex: sudoHost eq
```

apply the changes:

```
user@replica:~$ sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f indices.ldif

modifying entry "olcDatabase={1}hdb,cn=config"
```

Now we can check the replica index on the Master:

```
user@server:~$ sudo ldapsearch -x -LLL -W -D cn=admin,dc=mydomain,dc=com -s base -b dc=mydomain,dc=com contextCSN

Enter LDAP Password:
dn: dc=mydomain,dc=com
contextCSN: 20140814131434.915555Z#000000#000#000000
```

then check on the slave, if these two numbers match then we have replication:

```
user@replica:~$ sudo ldapsearch -x -LLL -W -D cn=admin,dc=mydomain,dc=com -s base -b dc=mydomain,dc=com contextCSN -H ldap:///
 
Enter LDAP Password:
dn: dc=mydomain,dc=com
contextCSN: 20140814131434.915555Z#000000#000#000000
```

It is same as on the provider which means success. We can now query the local database to confirm the whole DIT has synced:

```
user@replica:~$ sudo ldapsearch -x -LLL -W -D cn=admin,dc=mydomain,dc=com -b dc=mydomain,dc=com -H ldap:///
```

and we will see our entire DIT output.

### Adding the replica to our LDAP settings

Now that we have the replica working we can include this server to our setup so the clients and services will use it  in case the master is down. So the line in the clients PAM `/etc/ldap/ldap.conf` and SUDO `/etc/sudo-ldap.conf` config file reading:

```
URI ldap://my-ldap-server.mydomain.com
```

will become:

```
URI ldap://my-ldap-server.mydomain.com ldap://my-ldap-replica.mydomain.com
```

and the line in the autofs config file /etc/default/autofs reading:

```
LDAP_URI="ldap://my-ldap-server.mydomain.com:389/"
```

will become:

```
LDAP_URI="ldap://my-ldap-server.mydomain.com:389/ ldap://my-ldap-replica.mydomain.com"
```

and we need to add the replica to the PAM config file `/etc/ldap.conf` for the uri:

```
uri ldap://10.180.16.146:389/ ldap://10.180.18.237:389/
```
