---
type: posts
header:
  teaser: '42613560.jpeg'
title: 'PostgreSQL Confluence DB replication with Bucardo'
category: Database
tags: [postgresql, replication, high-availability]
date: 2016-9-19
excerpt: "In cases where we can’t use the built-in PostgreSQL replication facility, like for example Confluence DB which has replication protection, Bucardo is very efficient option..."
---

{% include toc %}

# Introduction

In cases where we can't use the built-in PostgreSQL replication facility, like for example Confluence DB which has replication protection, [Bucardo](http://bucardo.org/) is very efficient option. It is an asynchronous PostgreSQL replication system, allowing for both multi-master and multi-slave operations. Bucardo is free and open source software released under the BSD license.

In this case we use Bucardo to replicate Confluence from one site to another. As mentioned, each Confluence installation has a special table called `clustersafety` which has an auto-generated unique id associated upon every restart and thus can not be replicated since it exists in memory only and is never stored on disk. Unfortunately the native PostgreSQL replication does not have an option to exclude a table(s), it is all or nothing. That's where Bucardo comes in play.

Both DB's used by Confluence are on PostgreSQL-9.3 and the OS is Ubuntu-14.04.

# Setup

## Installation

Bucardo can be installed on any of the source or target DB server but can also be installed on a separate management server. In one directional replication, like in our case, it can be setup on the source (push) or target (pull) server. For bidirectional replication when we are running a master-master DB setup we can set it up on both servers.

Install needed packages on the target, in this case server2:

```
ubuntu@server2:~$ sudo aptitude install postgresql-plperl-9.3 libdbix-safe-perl libboolean-perl libdbd-pg-perl libtest-simple-perl libdbi-perl libdbd-pg-perl libboolean-perl wget build-essential libreadline-dev libz-dev autoconf bison libtool libgeos-c1 libproj-dev libgdal-dev libxml2-dev libxml2-utils libjson0-dev xsltproc docbook-xsl docbook-mathml libossp-uuid-dev libperl-dev libdbix-safe-perl
```

We can then install the bucardo package or compile from source if we want the latest stable version:

```
ubuntu@server2:~$ sudo mkdir /usr/src/bucardo
ubuntu@server2:~$ sudo chown ubuntu\: /usr/src/bucardo
ubuntu@server2:~$ cd /usr/src/bucardo
ubuntu@server2:~$ wget http://bucardo.org/downloads/Bucardo-5.4.1.tar.gz
ubuntu@server2:~$ tar -xzvf Bucardo-5.4.1.tar.gz
ubuntu@server2:~$ cd Bucardo-5.4.1/
ubuntu@server2:~$ perl Makefile.PL
ubuntu@server2:~$ make
ubuntu@server2:~$ make test
ubuntu@server2:~$ sudo make install
```

As a prerequisites, **ALL** tables in the replicated DB need to have primary key. Luckily in the Confluence db there is a single table missing one which is easy to fix on the source side, which is always the server1 instance:

```
ubuntu@server1:~$ sudo su - postgres
postgres@help:~$ psql confluence
psql (9.3.9)
Type "help" for help.
confluence=# SELECT table_catalog, table_schema, table_name FROM information_schema.tables WHERE table_type <> 'VIEW' AND (table_catalog, table_schema, table_name) NOT IN (SELECT table_catalog, table_schema, table_name FROM information_schema.table_constraints WHERE constraint_type = 'PRIMARY KEY') AND table_schema NOT IN ('information_schema', 'pg_catalog');
 table_catalog | table_schema |      table_name     
---------------+--------------+----------------------
 confluence    | public       | hibernate_unique_key
(1 row)
confluence=#
confluence=# ALTER TABLE hibernate_unique_key ADD PRIMARY KEY (next_hi);
ALTER TABLE
```

Login to the source and target DB's and create PL/Perl extension:

```
[ALL]$ sudo su - postgres
[ALL]$ psql
psql (9.3.9)
Type "help" for help.
 
postgres=# CREATE EXTENSION plperl;
CREATE EXTENSION
postgres=#
```

To setup the bucardo db we first create the PID directory:

```
ubuntu@server2:~$ sudo mkdir -p /var/run/bucardo
```

Then we run:

```
ubuntu@server2:~$ bucardo install
 
Current connection settings:
1. Host:           <none>
2. Port:           5432
3. User:           postgres
4. Database:       bucardo
5. PID directory:  /var/run/bucardo
Enter a number to change it, P to proceed, or Q to quit: 1
 
Change the host to: 127.0.0.1
 
Changed host to: 127.0.0.1
Current connection settings:
1. Host:           127.0.0.1
2. Port:           5432
3. User:           postgres
4. Database:       bucardo
5. PID directory:  /var/run/bucardo
Enter a number to change it, P to proceed, or Q to quit: P
 
Failed to connect to database 'bucardo', will try 'postgres'
Current connection settings:
1. Host:           127.0.0.1
2. Port:           5432
3. User:           postgres
4. Database:       postgres
5. PID directory:  /var/run/bucardo
Enter a number to change it, P to proceed, or Q to quit: P
 
Postgres version is: 9.3
Creating superuser 'bucardo'
Attempting to create and populate the bucardo database and schema
Database creation is complete
 
Updated configuration setting "piddir"
Installation is now complete.
If you see errors or need help, please email bucardo-general@bucardo.org
 
You may want to check over the configuration variables next, by running:
bucardo show all
Change any setting by using: bucardo set foo=bar
```

Then login to PostgreSQL and set the password for the bucardo user:

```
postgres=# ALTER USER bucardo WITH ENCRYPTED PASSWORD '<bucardo-password>';
ALTER ROLE
```

Now we create the user and the db we want to replicate on the local server, the replication target:

```
ubuntu@server2:~$ sudo -u postgres createuser -e -E -P confluence
Enter password for new role:
Enter it again:
CREATE ROLE confluence ENCRYPTED PASSWORD 'md5xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN;

ubuntu@server2:~$ sudo -u postgres createdb -e --encoding=UTF-8 --lc-collate=C --lc-ctype=C -T template0 -O confluence confluence
CREATE DATABASE confluence OWNER confluence ENCODING 'UTF-8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C';
```

## Source DB settings and initial schema dump to the target

To copy over the database from the source server we first need to make some config changes on the source side. Add connection permission in the source `pg_hba.conf` file by appending the following at the end of the `/etc/postgresql/9.3/main/pg_hba.conf` config file to allow connections from server2 over SSL:

```
[...]
hostssl all             postgres        <server2-ip>/32        trust
hostssl confluence      confluence      <server2-ip>/32        md5
hostssl all             bucardo         <server2-ip>/32        md5
```

PostgreSQL by default listens on the local interface only so in the `/etc/postgresql/9.3/main/postgresql.conf` conf file we add:

```
listen_address = '*';
```

We also need to create the Bucardo super user with some strong password:

```
ubuntu@server1:~$ sudo -u postgres CREATE USER bucardo WITH LOGIN SUPERUSER ENCRYPTED PASSWORD '<bucardo-password>';
```

and restart the database so the postgres user can connect remotely from the target server.

Then on the target server2 we run:

```
ubuntu@server2:~$ pg_dump -v -U postgres -h server1.mydomain.com -d confluence --schema-only | sudo -u postgres psql confluence
```

to copy over the Confluence DB schema.

## Firewall

We need to open the TCP port `5432` in the source server firewall for access from the target server only.

## Setting up Bucardo Sync

With the databases ready to go, we can now configure Bucardo itself. First lets test the bucardo user connection from the target to the source server:

```
ubuntu@server2:~$ psql -h server1.mydomain.com -U bucardo -W -d confluence
Password for user bucardo:
psql (9.3.10, server 9.3.9)
SSL connection (cipher: DHE-RSA-AES256-GCM-SHA384, bits: 256)
Type "help" for help.
 
confluence=# \d
confluence=# \q
```

Now we can add the Source Database first enabling ssl mode so the transfers are encrypted:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> add db source_db dbname=confluence host=server1.mydomain.com user=bucardo pass=<bucardo-password> conn=sslmode=require
Added database "source_db"
```

Then we add the Destination Database which is running on the local host:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> add db target_db dbname=confluence host=127.0.0.1 user=bucardo pass=<bucardo-password>
```

We add the tables and sequences we want to migrate from the source database but we want to exclude the `clustersafety` table from the replication as it is a protection in Confluence against db syncing:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> add all tables --exclude-table clustersafety db=source_db relgroup=confluence_db_group
Creating relgroup: confluence_db_group
Added table public.AO_187CCC_SIDEBAR_LINK to relgroup confluence_db_group
Added table public.AO_21D670_WHITELIST_RULES to relgroup confluence_db_group
Added table public.AO_38321B_CUSTOM_CONTENT_LINK to relgroup confluence_db_group
Added table public.AO_42E351_HEALTH_CHECK_ENTITY to relgroup confluence_db_group
Added table public.AO_54C900_SPACE_BLUEPRINT_AO to relgroup confluence_db_group
Added table public.AO_5F3884_FEATURE_DISCOVERY to relgroup confluence_db_group
Added table public.AO_6384AB_FEATURE_METADATA_AO to relgroup confluence_db_group
Added table public.AO_92296B_AORECENTLY_VIEWED to relgroup confluence_db_group
Added table public.AO_9412A1_AONOTIFICATION to relgroup confluence_db_group
Added table public.AO_9412A1_AOREGISTRATION to relgroup confluence_db_group
Added table public.AO_9412A1_AOTASK to relgroup confluence_db_group
Added table public.AO_DC98AE_AOHELP_TIP to relgroup confluence_db_group
Added table public.AO_A0B856_WEB_HOOK_LISTENER_AO to relgroup confluence_db_group
Added table public.AO_EF9604_FEATURE_DISCOVERY to relgroup confluence_db_group
Added table public.AO_9412A1_AOUSER to relgroup confluence_db_group
Added table public.attachmentdata to relgroup confluence_db_group
Added table public.bandana to relgroup confluence_db_group
Added table public.AO_9412A1_USER_APP_LINK to relgroup confluence_db_group
Added table public.confversion to relgroup confluence_db_group
Added table public.cwd_directory to relgroup confluence_db_group
Added table public.confancestors to relgroup confluence_db_group
Added table public.content_perm_set to relgroup confluence_db_group
Added table public.contentproperties to relgroup confluence_db_group
Added table public.bodycontent to relgroup confluence_db_group
Added table public.content_label to relgroup confluence_db_group
Added table public.cwd_app_dir_group_mapping to relgroup confluence_db_group
Added table public.cwd_group to relgroup confluence_db_group
Added table public.cwd_application to relgroup confluence_db_group
Added table public.cwd_directory_operation to relgroup confluence_db_group
Added table public.cwd_app_dir_operation to relgroup confluence_db_group
Added table public.content_perm to relgroup confluence_db_group
Added table public.cwd_membership to relgroup confluence_db_group
Added table public.cwd_directory_attribute to relgroup confluence_db_group
Added table public.cwd_group_attribute to relgroup confluence_db_group
Added table public.cwd_application_attribute to relgroup confluence_db_group
Added table public.cwd_application_address to relgroup confluence_db_group
Added table public.os_group to relgroup confluence_db_group
Added table public.imagedetails to relgroup confluence_db_group
Added table public.os_user to relgroup confluence_db_group
Added table public.decorator to relgroup confluence_db_group
Added table public.hibernate_unique_key to relgroup confluence_db_group
Added table public.keystore to relgroup confluence_db_group
Added table public.external_entities to relgroup confluence_db_group
Added table public.cwd_user to relgroup confluence_db_group
Added table public.groups to relgroup confluence_db_group
Added table public.follow_connections to relgroup confluence_db_group
Added table public.indexqueueentries to relgroup confluence_db_group
Added table public.label to relgroup confluence_db_group
Added table public.local_members to relgroup confluence_db_group
Added table public.likes to relgroup confluence_db_group
Added table public.external_members to relgroup confluence_db_group
Added table public.extrnlnks to relgroup confluence_db_group
Added table public.logininfo to relgroup confluence_db_group
Added table public.os_propertyentry to relgroup confluence_db_group
Added table public.links to relgroup confluence_db_group
Added table public.cwd_user_attribute to relgroup confluence_db_group
Added table public.cwd_user_credential_record to relgroup confluence_db_group
Added table public.trackbacklinks to relgroup confluence_db_group
Added table public.user_mapping to relgroup confluence_db_group
Added table public.plugindata to relgroup confluence_db_group
Added table public.remembermetoken to relgroup confluence_db_group
Added table public.os_user_group to relgroup confluence_db_group
Added table public.users to relgroup confluence_db_group
Added table public.spaces to relgroup confluence_db_group
Added table public.trustedapp to relgroup confluence_db_group
Added table public.trustedapprestriction to relgroup confluence_db_group
Added table public.spacepermissions to relgroup confluence_db_group
Added table public.attachments to relgroup confluence_db_group
Added table public.cwd_app_dir_mapping to relgroup confluence_db_group
Added table public.spacegrouppermissions to relgroup confluence_db_group
Added table public.pagetemplates to relgroup confluence_db_group
Added table public.spacegroups to relgroup confluence_db_group
Added table public.content to relgroup confluence_db_group
Added table public.AO_54C900_CONTENT_BLUEPRINT_AO to relgroup confluence_db_group
Added table public.AO_54C900_C_TEMPLATE_REF to relgroup confluence_db_group
Added table public.notifications to relgroup confluence_db_group
New tables added: 76
```

This command creates the relation group called `confluence_db_group` for us too which contains the list of tables and sequences we add to replication. Next we add the db sequences too:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> add all sequences db=source_db relgroup=confluence_db_group
Added sequence public.AO_187CCC_SIDEBAR_LINK_ID_seq to relgroup confluence_db_group
Added sequence public.AO_21D670_WHITELIST_RULES_ID_seq to relgroup confluence_db_group
Added sequence public.AO_38321B_CUSTOM_CONTENT_LINK_ID_seq to relgroup confluence_db_group
Added sequence public.AO_42E351_HEALTH_CHECK_ENTITY_ID_seq to relgroup confluence_db_group
Added sequence public.AO_54C900_CONTENT_BLUEPRINT_AO_ID_seq to relgroup confluence_db_group
Added sequence public.AO_54C900_C_TEMPLATE_REF_ID_seq to relgroup confluence_db_group
Added sequence public.AO_54C900_SPACE_BLUEPRINT_AO_ID_seq to relgroup confluence_db_group
Added sequence public.AO_5F3884_FEATURE_DISCOVERY_ID_seq to relgroup confluence_db_group
Added sequence public.AO_6384AB_FEATURE_METADATA_AO_ID_seq to relgroup confluence_db_group
Added sequence public.AO_92296B_AORECENTLY_VIEWED_ID_seq to relgroup confluence_db_group
Added sequence public.AO_9412A1_AONOTIFICATION_ID_seq to relgroup confluence_db_group
Added sequence public.AO_9412A1_AOTASK_ID_seq to relgroup confluence_db_group
Added sequence public.AO_9412A1_AOUSER_ID_seq to relgroup confluence_db_group
Added sequence public.AO_9412A1_USER_APP_LINK_ID_seq to relgroup confluence_db_group
Added sequence public.AO_A0B856_WEB_HOOK_LISTENER_AO_ID_seq to relgroup confluence_db_group
Added sequence public.AO_DC98AE_AOHELP_TIP_ID_seq to relgroup confluence_db_group
Added sequence public.AO_EF9604_FEATURE_DISCOVERY_ID_seq to relgroup confluence_db_group
New sequences added: 17
```

In case we have added all tables by mistake then later we can remove the `clustersafety` table from the replication:

```
$ bucardo -U bucardo -d bucardo -P <bucardo-password> remove table public.clustersafety db=source_db
Removed the following tables:
  public.clustersafety (DB: source_db)
```

Next we create the dbgroup:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> add dbgroup confluence_db_group source_db:source target_db:target
Created dbgroup "confluence_db_group"
Added database "source_db" to dbgroup "confluence_db_group" as source
Added database "target_db" to dbgroup "confluence_db_group" as target
```

And create the sync with `autokick=0` to prevent Bucardo to start replicating in case it is running:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> add sync confluence_sync relgroup=confluence_db_group dbs=confluence_db_group autokick=0
Added sync "confluence_sync"
```

We can also tell Bucardo to validate the sync:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> validate confluence_sync
Validating sync confluence_sync ... OK
```

Now it's time to migrate the data:

```
ubuntu@server2:~$ pg_dump -v -U postgres -h server1.mydomain.com -d confluence --data-only --disable-triggers -N bucardo | PGOPTIONS='-c session_replication_role=replica' sudo -u postgres psql confluence
```

and after that's finished we can enable the sync autokick:

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> update sync confluence_sync autokick=1
```

The parameter `autokick=1` means Bucardo will monitor the table changes on the source and trigger sync in case of any changes.

At the end we start Bucardo:

```
ubuntu@server2~$ sudo mkdir -p /var/log/bucardo
ubuntu@server2~$ sudo bucardo -U bucardo -d bucardo -P <bucardo-password> start
```

To check the Bucardo sync status:

```
ubuntu@server2:/usr/src/bucardo/Bucardo-5.4.1$ sudo bucardo -U bucardo -d bucardo -P <bucardo-password> status confluence_sync
======================================================================
Sync name                : confluence_sync
Current state            : No records found
Source relgroup/database : confluence_db_group / source_db
Tables in sync           : 93
Status                   : Active
Check time               : None
Overdue time             : 00:00:00
Expired time             : 00:00:00
Stayalive/Kidsalive      : Yes / Yes
Rebuild index            : No
Autokick                 : Yes
Onetimecopy              : No
Post-copy analyze        : Yes
Last error:              :
======================================================================
```

After waiting for some time we can check the Bucardo sync status again:

```
ubuntu@server2~$ sudo bucardo -U bucardo -d bucardo -P <bucardo-password> status confluence_sync
 
======================================================================
Last good                : Oct 05, 2015 09:26:01 (time to run: 22s)
Rows deleted/inserted    : 2 / 2
Sync name                : confluence_sync
Current state            : Good
Source relgroup/database : confluence_db_group / source_db
Tables in sync           : 93
Status                   : Active
Check time               : None
Overdue time             : 00:00:00
Expired time             : 00:00:00
Stayalive/Kidsalive      : Yes / Yes
Rebuild index            : No
Autokick                 : Yes
Onetimecopy              : No
Post-copy analyze        : Yes
Last error:              :
======================================================================
```

and we can see couple of changes have been applied. We can set this to email us via crontab for ubuntu user:

```
0 */6 * * * /usr/local/bin/bucardo -U bucardo -d bucardo -P <bucardo-password> status confluence_sync | /usr/bin/mail -s "Bucardo status" user@mydomain.com
```

This will send us email with Bucardo status every 6 hours so we can notice if anything broken.

At the end we can check the Bucardo postgres processes on the target:

```
ubuntu@server2:~$ ps ax -o pid,command | grep postgres | grep bucardo
 2698 postgres: bucardo bucardo [local] idle                                                                                     
 2702 postgres: bucardo confluence 127.0.0.1(15944) idle                                                                         
 3188 postgres: bucardo bucardo [local] idle                                                                                     
 3192 postgres: bucardo bucardo [local] idle                                                                                     
 3205 postgres: bucardo confluence 127.0.0.1(15958) idle                                                                         
 3309 postgres: bucardo bucardo [local] idle                                                                                     
 3325 postgres: bucardo confluence 127.0.0.1(15981) idle
```

and the source server:

```
ubuntu@server1:~$ ps ax -o pid,command | grep postgres | grep bucardo
 5122 postgres: bucardo confluence <server2-ip>(48271) idle                                                                      
 5692 postgres: bucardo confluence <server2-ip>(48285) idle                                                                      
 5693 postgres: bucardo confluence <server2-ip>(48286) idle                                                                      
 5954 postgres: bucardo confluence <server2-ip>(48309) idle
```

## Some useful commands

```
ubuntu@server2:~$ bucardo -U bucardo -d bucardo -P <bucardo-password> list tables
1.  Table: public.AO_187CCC_SIDEBAR_LINK          DB: source_db  PK: ID (integer)                                            
2.  Table: public.AO_21D670_WHITELIST_RULES       DB: source_db  PK: ID (integer)                                            
3.  Table: public.AO_38321B_CUSTOM_CONTENT_LINK   DB: source_db  PK: ID (integer)                                            
4.  Table: public.AO_42E351_HEALTH_CHECK_ENTITY   DB: source_db  PK: ID (integer)                                            
74. Table: public.AO_54C900_CONTENT_BLUEPRINT_AO  DB: source_db  PK: ID (integer)                                            
75. Table: public.AO_54C900_C_TEMPLATE_REF        DB: source_db  PK: ID (integer)                                            
5.  Table: public.AO_54C900_SPACE_BLUEPRINT_AO    DB: source_db  PK: ID (integer)                                            
6.  Table: public.AO_5F3884_FEATURE_DISCOVERY     DB: source_db  PK: ID (integer)                                            
7.  Table: public.AO_6384AB_FEATURE_METADATA_AO   DB: source_db  PK: ID (integer)                                            
8.  Table: public.AO_92296B_AORECENTLY_VIEWED     DB: source_db  PK: ID (bigint)                                             
9.  Table: public.AO_9412A1_AONOTIFICATION        DB: source_db  PK: ID (bigint)                                             
10. Table: public.AO_9412A1_AOREGISTRATION        DB: source_db  PK: ID (varchar)                                            
11. Table: public.AO_9412A1_AOTASK                DB: source_db  PK: ID (bigint)                                             
15. Table: public.AO_9412A1_AOUSER                DB: source_db  PK: ID (bigint)                                             
18. Table: public.AO_9412A1_USER_APP_LINK         DB: source_db  PK: ID (bigint)                                             
13. Table: public.AO_A0B856_WEB_HOOK_LISTENER_AO  DB: source_db  PK: ID (integer)                                            
12. Table: public.AO_DC98AE_AOHELP_TIP            DB: source_db  PK: ID (integer)                                            
14. Table: public.AO_EF9604_FEATURE_DISCOVERY     DB: source_db  PK: ID (integer)                                            
16. Table: public.attachmentdata                  DB: source_db  PK: attachmentdataid (bigint)                               
68. Table: public.attachments                     DB: source_db  PK: attachmentid (bigint)                                   
17. Table: public.bandana                         DB: source_db  PK: bandanaid (bigint)                                      
24. Table: public.bodycontent                     DB: source_db  PK: bodycontentid (bigint)                                  
21. Table: public.confancestors                   DB: source_db  PK: descendentid|ancestorposition (bigint|integer)          
19. Table: public.confversion                     DB: source_db  PK: confversionid (bigint)                                  
73. Table: public.content                         DB: source_db  PK: contentid (bigint)                                      
25. Table: public.content_label                   DB: source_db  PK: id (bigint)                                             
31. Table: public.content_perm                    DB: source_db  PK: id (bigint)                                             
22. Table: public.content_perm_set                DB: source_db  PK: id (bigint)                                             
23. Table: public.contentproperties               DB: source_db  PK: propertyid (bigint)                                     
26. Table: public.cwd_app_dir_group_mapping       DB: source_db  PK: id (bigint)                                             
69. Table: public.cwd_app_dir_mapping             DB: source_db  PK: id (bigint)                                             
30. Table: public.cwd_app_dir_operation           DB: source_db  PK: app_dir_mapping_id|operation_type (bigint|varchar)      
28. Table: public.cwd_application                 DB: source_db  PK: id (bigint)                                             
36. Table: public.cwd_application_address         DB: source_db  PK: application_id|remote_address (bigint|varchar)          
35. Table: public.cwd_application_attribute       DB: source_db  PK: application_id|attribute_name (bigint|varchar)          
20. Table: public.cwd_directory                   DB: source_db  PK: id (bigint)                                             
33. Table: public.cwd_directory_attribute         DB: source_db  PK: directory_id|attribute_name (bigint|varchar)            
29. Table: public.cwd_directory_operation         DB: source_db  PK: directory_id|operation_type (bigint|varchar)            
27. Table: public.cwd_group                       DB: source_db  PK: id (bigint)                                             
34. Table: public.cwd_group_attribute             DB: source_db  PK: id (bigint)                                             
32. Table: public.cwd_membership                  DB: source_db  PK: id (bigint)                                             
44. Table: public.cwd_user                        DB: source_db  PK: id (bigint)                                             
56. Table: public.cwd_user_attribute              DB: source_db  PK: id (bigint)                                             
57. Table: public.cwd_user_credential_record      DB: source_db  PK: id (bigint)                                             
40. Table: public.decorator                       DB: source_db  PK: decoratorid (bigint)                                    
43. Table: public.external_entities               DB: source_db  PK: id (bigint)                                             
51. Table: public.external_members                DB: source_db  PK: groupid|extentityid (bigint|int8)                       
52. Table: public.extrnlnks                       DB: source_db  PK: linkid (bigint)                                         
46. Table: public.follow_connections              DB: source_db  PK: connectionid (bigint)                                   
45. Table: public.groups                          DB: source_db  PK: id (bigint)                                             
41. Table: public.hibernate_unique_key            DB: source_db  PK: next_hi (integer)                                       
38. Table: public.imagedetails                    DB: source_db  PK: attachmentid (bigint)                                   
47. Table: public.indexqueueentries               DB: source_db  PK: entryid (bigint)                                        
42. Table: public.keystore                        DB: source_db  PK: keyid (bigint)                                          
48. Table: public.label                           DB: source_db  PK: labelid (bigint)                                        
50. Table: public.likes                           DB: source_db  PK: id (bigint)                                             
55. Table: public.links                           DB: source_db  PK: linkid (bigint)                                         
49. Table: public.local_members                   DB: source_db  PK: groupid|userid (bigint|int8)                            
53. Table: public.logininfo                       DB: source_db  PK: id (bigint)                                             
76. Table: public.notifications                   DB: source_db  PK: notificationid (bigint)                                 
37. Table: public.os_group                        DB: source_db  PK: id (bigint)                                             
54. Table: public.os_propertyentry                DB: source_db  PK: entity_name|entity_id|entity_key (varchar|bigint|varchar)
39. Table: public.os_user                         DB: source_db  PK: id (bigint)                                             
62. Table: public.os_user_group                   DB: source_db  PK: user_id|group_id (bigint|int8)                          
71. Table: public.pagetemplates                   DB: source_db  PK: templateid (bigint)                                     
60. Table: public.plugindata                      DB: source_db  PK: plugindataid (bigint)                                   
61. Table: public.remembermetoken                 DB: source_db  PK: id (bigint)                                             
70. Table: public.spacegrouppermissions           DB: source_db  PK: spacegrouppermid (bigint)                               
72. Table: public.spacegroups                     DB: source_db  PK: spacegroupid (bigint)                                   
67. Table: public.spacepermissions                DB: source_db  PK: permid (bigint)                                         
64. Table: public.spaces                          DB: source_db  PK: spaceid (bigint)                                        
58. Table: public.trackbacklinks                  DB: source_db  PK: linkid (bigint)                                         
65. Table: public.trustedapp                      DB: source_db  PK: trustedappid (bigint)                                   
66. Table: public.trustedapprestriction           DB: source_db  PK: trustedapprestrictionid (bigint)                        
59. Table: public.user_mapping                    DB: source_db  PK: user_key (varchar)                                      
63. Table: public.users                           DB: source_db  PK: id (bigint)

$ tail -f /var/log/bucardo/log.bucardo
.
.
(29294) [Mon Oct  5 09:19:28 2015] MCP   Inspecting source sequence "public.AO_9412A1_AOUSER_ID_seq" on database "source_db"
(29294) [Mon Oct  5 09:19:28 2015] MCP   Inspecting source sequence "public.AO_9412A1_USER_APP_LINK_ID_seq" on database "source_db"
(29294) [Mon Oct  5 09:19:28 2015] MCP   Inspecting source sequence "public.AO_A0B856_WEB_HOOK_LISTENER_AO_ID_seq" on database "source_db"
(29294) [Mon Oct  5 09:19:29 2015] MCP   Inspecting source sequence "public.AO_DC98AE_AOHELP_TIP_ID_seq" on database "source_db"
(29294) [Mon Oct  5 09:19:29 2015] MCP   Inspecting source sequence "public.AO_EF9604_FEATURE_DISCOVERY_ID_seq" on database "source_db"
(29294) [Mon Oct  5 09:19:32 2015] MCP Active syncs: 1
(29294) [Mon Oct  5 09:19:32 2015] MCP Entering main loop
(29319) [Mon Oct  5 09:19:32 2015] VAC New VAC daemon. PID=29319
(29294) [Mon Oct  5 09:19:32 2015] MCP Created VAC 29319
(29321) [Mon Oct  5 09:19:33 2015] CTL New controller for sync "confluence_sync". Relgroup is "confluence_db_group", dbs is "confluence_db_group". PID=29321
(29321) [Mon Oct  5 09:19:33 2015] CTL   stayalive: 1 checksecs: 0 kicked: 1
(29321) [Mon Oct  5 09:19:33 2015] CTL   kidsalive: 1 onetimecopy: 1 lifetimesecs: 0 (NULL) maxkicks: 0
(29294) [Mon Oct  5 09:19:33 2015] MCP Created controller 29321 for sync "confluence_sync". Kick is 1
(29319) [Mon Oct  5 09:19:37 2015] VAC Connected to database "source_db" with backend PID of 18349
(29321) [Mon Oct  5 09:19:37 2015] CTL Database "source_db" backend PID: 18350
(29321) [Mon Oct  5 09:19:37 2015] CTL Database "target_db" backend PID: 29324
(29341) [Mon Oct  5 09:23:35 2015] KID (confluence_sync) New kid, sync "confluence_sync" alive=1 Parent=29321 PID=29341 kicked=1 OTC: 1
(29341) [Mon Oct  5 09:25:45 2015] KID (confluence_sync) Total target rows deleted: 15781
(29341) [Mon Oct  5 09:25:45 2015] KID (confluence_sync) Total target rows copied: 15781
(29341) [Mon Oct  5 09:25:46 2015] KID (confluence_sync) Total time for sync "confluence_sync" (15781 rows, 0 tables): 2 minutes 5 seconds (125.95 seconds)
(29341) [Mon Oct  5 09:25:46 2015] KID (confluence_sync) Kid 29341 exiting at cleanup_kid.  Reason: Normal exit
(29358) [Mon Oct  5 09:25:56 2015] KID (confluence_sync) New kid, sync "confluence_sync" alive=1 Parent=29321 PID=29358 kicked=1
(29358) [Mon Oct  5 09:26:20 2015] KID (confluence_sync) Delta count for source_db.public.bandana                          : 2
(29358) [Mon Oct  5 09:26:21 2015] KID (confluence_sync) Totals: deletes=2 inserts=2 conflicts=0
(29358) [Mon Oct  5 09:46:02 2015] KID (confluence_sync) Delta count for source_db.public.bandana                          : 2
(29358) [Mon Oct  5 09:46:04 2015] KID (confluence_sync) Totals: deletes=2 inserts=2 conflicts=0
(29358) [Mon Oct  5 10:36:18 2015] KID (confluence_sync) Delta count for source_db.public.extrnlnks                        : 1
(29358) [Mon Oct  5 10:36:18 2015] KID (confluence_sync) Totals: deletes=1 inserts=1 conflicts=0
(29358) [Mon Oct  5 10:46:02 2015] KID (confluence_sync) Delta count for source_db.public.bandana                          : 2
(29358) [Mon Oct  5 10:46:03 2015] KID (confluence_sync) Totals: deletes=2 inserts=2 conflicts=0
(29358) [Mon Oct  5 11:03:08 2015] KID (confluence_sync) Delta count for source_db.public.logininfo                        : 1
(29358) [Mon Oct  5 11:03:08 2015] KID (confluence_sync) Delta count for source_db.public.cwd_user_attribute               : 1
(29358) [Mon Oct  5 11:03:09 2015] KID (confluence_sync) Totals: deletes=2 inserts=2 conflicts=0
(29358) [Mon Oct  5 11:06:22 2015] KID (confluence_sync) Delta count for source_db.public."AO_92296B_AORECENTLY_VIEWED"    : 1
(29358) [Mon Oct  5 11:06:23 2015] KID (confluence_sync) Totals: deletes=1 inserts=1 conflicts=0
(29358) [Mon Oct  5 11:06:44 2015] KID (confluence_sync) Delta count for source_db.public."AO_92296B_AORECENTLY_VIEWED"    : 1
(29358) [Mon Oct  5 11:06:44 2015] KID (confluence_sync) Totals: deletes=1 inserts=1 conflicts=0
(29358) [Mon Oct  5 11:46:02 2015] KID (confluence_sync) Delta count for source_db.public.bandana                          : 2
(29358) [Mon Oct  5 11:46:03 2015] KID (confluence_sync) Totals: deletes=2 inserts=2 conflicts=0
(29358) [Mon Oct  5 12:46:02 2015] KID (confluence_sync) Delta count for source_db.public.bandana                          : 2
(29358) [Mon Oct  5 12:46:03 2015] KID (confluence_sync) Totals: deletes=2 inserts=2 conflicts=0
```

Useful thing we can see here is that full confluence sync takes 2 minutes and 5 seconds.

## DB Monitoring

We can use the `tail_n_mail` script provided by Bucardo to monitor the source database (https://bucardo.org/wiki/Tail_n_mail). Install the script:

```
root@server1:~# wget -o /usr/local/bin/tail_n_mail.pl http://bucardo.org/downloads/tail_n_mail
root@server1:~# chmod +x /usr/local/bin/tail_n_mail.pl
```

Setup the error log file in `/etc/postgresql/9.3/main/postgresql.conf`:

```
[..]
log_destination = 'stderr'        # Valid values are combinations of
logging_collector = on            # Enable capturing of stderr and csvlog
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_size = 10MB        # Automatic rotation of logfiles will
log_line_prefix='%t [%p] %u@%d '
[..]
```

Create rc file `/root/.tailnmailrc` containing the `log_line_prefix` setting from above:

```
log_line_prefix='%t [%p] %u@%d '
```

Generate config file:

```
root@server1:~# tail /usr/local/bin/tail_n_mail.pl > tnm.config.txt
```

and modify it to suit us:

```
$ sudo vi /root/tnm.config.txt
## Config file for the tail_n_mail program
## This file is automatically updated
EMAIL: igorc@encompasscorporation.com
MAILSUBJECT: Encompass HOST Postgres errors UNIQUE : NUMBER
 
FILE: /var/log/postgresql/postgresql-%Y-%m-%d.log
INCLUDE: ERROR: 
INCLUDE: FATAL: 
INCLUDE: PANIC:
```

Test run:

```
root@server1:~# perl /usr/local/bin/tail_n_mail.pl tnm.config.txt
```

and I received an email, all working fine. Finally create a cron job that runs every 5 minutes:

```
*/5 * * * * perl /usr/local/bin/tail_n_mail.pl /root/tnm.config.txt
```
