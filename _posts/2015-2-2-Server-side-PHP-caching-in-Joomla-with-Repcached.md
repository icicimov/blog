---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Server side PHP caching in Joomla! with Repcached'
categories: 
  - Webserver
tags: [memcached,joomla,high-availability]
date: 2015-2-2
---

Caching provides significant performance speed up since reading data from the memory is much faster then reading it from the database or disk, especially if it resides on a different server. In our case they are on the same one but still in memory caching can provide some speed gains. Since our setup is fully HA we need to reflect this on to the caching as well, meaning data like PHP sessions needs to be cached on both nodes. One pretty simple solution is `Repcached`, which is nothing else but clustered `Memcached` daemon. On both nodes we do:

```
$ sudo aptitude install libevent1-dev
$ sudo aptitude build-dep memcached
$ wget memcached-1.2.8-repcached-2.2.1.tar.gz
$ tar -xzvf memcached-1.2.8-repcached-2.2.1.tar.gz
$ cd memcached-1.2.8-repcached-2.2.1
$ ./configure --enable-replication
$ make && sudo make install
```

which installs repcached in /usr/local/bin/memcached. Now we can start the service on both nodes:

```
root@ip-172-31-119-7:~# /usr/local/bin/memcached -m 128 -p 11211 -u memcache -X 11212 -x 172.31.19.153 -v
replication: connect (peer=172.31.19.153:11212)
replication: marugoto copying
replication: close
replication: listen
replication: accept
 
root@ip-172-31-119-53:~# /usr/local/bin/memcached -m 128 -p 11211 -u memcache -X 11212 -x 172.31.19.17 -v
replication: connect (peer=172.31.19.17:11212)
replication: marugoto copying
replication: start
```

and confirm they connect to each other and are ready for replication. The repcached listens on tcp port 11211 on the local node and accepts connections from its peer on tcp port 11212. To confirm the replication working we store some value on server 1 and read it on server 2:

```
root@ip-172-31-119-7:~# telnet 127.0.0.1 11211
Trying 127.0.0.1...
Connected to 127.0.0.1.
Escape character is '^]'.
set foo 0 0 3
bar
STORED
  
root@ip-172-31-119-53:~# telnet 127.0.0.1 11211
Trying 127.0.0.1...
Connected to 127.0.0.1.
Escape character is '^]'.
get foo
VALUE foo 0 3
bar
END
```

and also the other way around:

```
root@ip-172-31-119-53:~# telnet 127.0.0.1 11211
Trying 127.0.0.1...
Connected to 127.0.0.1.
Escape character is '^]'.
set hello 0 0 5
world
STORED
 
root@ip-172-31-119-7:~# telnet 127.0.0.1 11211
Trying 127.0.0.1...
Connected to 127.0.0.1.
Escape character is '^]'.
get hello
VALUE hello 0 5
world
END
```

Now we need to install and enable the memcache extension in PHP so we can utilize the cache:

```
$ sudo aptitude install php5-memcache php5-memcached
$ sudo php5enmod memcache
$ sudo php5enmod memcached
```

and configure it in `/etc/php5/cgi/php.ini` file by replacing:

```
session.save_handler = files
session.save_path = "/var/www/html/tmp"
```

with:

```
session.save_handler = memcache
session.save_handler = memcached
session.save_path = "tcp://172.31.19.17:11211?persistent=1,tcp://172.31.19.153:11211?persistent=1"
```

and reload apache on both nodes:

```
$ sudo service apache2 reload
```

As we can notice I already had PHP caching set to file system path `/var/www/html/tmp`, meaning caching on the shared file system, which is also an option for having a shared cache.

Now we can enable the Joomla! built in `System Page Cache` plugin and the Module's Cache under `Global Configuration --> System`, by choosing the `Conservative Caching` option and `Memcached` as `Cache Handler`. After some time we will see some cached entries:

```
root@ip-172-31-119-7:/var/www/html$ echo 'stats cachedump 3 10' | nc 0 11211
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-page-f411954e67e8df28227048b4ef13e318_lock [1 b; 1424136491 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-sh404sef_analytics_auth-068044fa245bc3e910a7df006eef5e64_lock [1 b; 1424091909 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-page-4af3ac7e45e5a5a85f3f2bb065da4e5f_lock [1 b; 1424079984 s]
END
```

in this case some page cache and cache from the `sh404SEF` Joomla! module. And if we check the values of the keys stored in slab 3 on the other server:

```
root@ip-172-31-119-53:~# echo 'stats cachedump 3 10' | nc 0 11211
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-page-f411954e67e8df28227048b4ef13e318_lock [1 b; 1424136491 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-sh404sef_analytics_auth-068044fa245bc3e910a7df006eef5e64_lock [1 b; 1424091909 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-page-4af3ac7e45e5a5a85f3f2bb065da4e5f_lock [1 b; 1424079984 s]
END
```

we will see they are identical, another confirmation the replication is working. And if we check slab 11 for example:

```
stats cachedump 11 100
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-mod_menu-769fa07cdfd70c7344d4827fdaddb672 [742 b; 1424664176 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-com_languages-150645621128f97f4134a1707ca9cc6c [814 b; 1424664159 s]
ITEM memc.sess.key.tpbetjdd03k0e4ju4vm30hl974 [975 b; 1424662910 s]
ITEM memc.sess.key.74fk4ufueaa17nvbhvutbg6sq1 [975 b; 1424662910 s]
ITEM memc.sess.key.p5m69ggh6j6f750di77m2d0oo0 [975 b; 1424662909 s]
ITEM memc.sess.key.beop5c8cclp2s2vq50kfuvtkp4 [923 b; 1424662907 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-mod_custom-6899858c5696c07d9e22ad099741eb11 [923 b; 1424657022 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-mod_menu-e3ab9c649c1884e99f65638867a4ccaa [742 b; 1424657022 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-mod_menu-05c788ee4b344a4d5a61f2adfbeffac4 [883 b; 1424657020 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-_system-a7be9b9967636d025387c33e073c5b05 [760 b; 1424657015 s]
ITEM ee9b6e4d56e7aaf7b015608a4ffd4465-cache-mod_breadcrumbs-78272508895bfe648dc479c8c1d49475 [720 b; 1424655525 s]
...
```

we can see here caching from some other modules and some cached PHP sessions too (the memc.sess.key.* items).

If we ever want to clear the cache we run:

```
$ echo 'flush_all' | nc localhost 11211
OK
```

on both servers. Some other useful commands:

```
$ echo 'stats' | nc 0 11211
$ echo 'stats items' | nc 0 11211
$ echo 'stats slabs' | nc 0 11211
$ echo 'stats sizes' | nc 0 11211
```
