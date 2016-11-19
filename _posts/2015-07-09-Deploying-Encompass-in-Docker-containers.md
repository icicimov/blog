---
type: posts
header:
  teaser: 'docker1.png'
title: 'Deploying Encompass In Docker Containers'
categories: 
  - Docker
tags: [docker, containers, virtualizasion]
---

At the beginning, just a short summery of how we can start using out container images.

## Using Containers

For the users to be able to use this repository they first need to create account on [DockerHub](https://hub.docker.com/). After I add the person's user name to the repository, the user will be able to pull the images to their local station:

```
$ sudo docker login
$ sudo docker pull <my-user>/<my-repository>
```

and then start the containers as described before. Or just run:

```
$ sudo docker run -d --name="ElasticSearch" -t -i <my-user>/<my-repository>:elastic_search
$ sudo docker run -d --name="MongoDB" -t -i <my-user>/<my-repository>:mongodb
$ sudo docker run -d --name="Tomcat" --link MongoDB:db --link ElasticSearch:es -t -i <my-user>/<my-repository>:tomcat7
```

and Docker will do the pulling and start the containers. Then find the IP address of the Tomcat container:

```
{% raw %}
$ sudo docker inspect --format '{{ .NetworkSettings.IPAddress }}' 874bc9860811
172.17.0.4
{% endraw %}
```

and set your hosts file, for example:

```
...
172.17.0.4  devtest
...
```

Now you can connect to your devtest instance at `https://devtest/`:

```
$ curl -k -s -S -I --ciphers RC4-SHA:RC4-MD5 https://devtest/
HTTP/1.1 200 OK
Server: Apache-Coyote/1.1
Cache-Control: no-cache
Expires: Thu, 01 Jan 1970 00:00:00 GMT
Set-Cookie: JSESSIONID=A4FF38616101E27FB7F9464DAC92217F.app1-prod; Path=/; Secure; HttpOnly
Pragma: no-cache
Content-Type: text/html;charset=UTF-8
Content-Length: 2634
Vary: Accept-Encoding
Date: Thu, 20 Nov 2014 07:06:57 GMT
```

As said before, if you want to expose the Tomcat applications to the host and its local network then start Tomcat as follows:

```
$ sudo docker run -d --name="Tomcat" --link MongoDB:db --link ElasticSearch:es -p 443:443 -t -i <my-user>/<my-repository>:tomcat7
```

to map its port to 443 on the host or any other port if host's 443 is already taken by some other process. Please refer to `Deploying/Redeploying Encompass In Docker Containers` section further down in this page to learn how to start Tomcat container with different versions of the Encompass and/or Admin application from the one(s) built into the container. Sometimes it makes sense building the development Tomcat container without any built in applications and pass the war files to it on start up. This makes it much more flexible and lightweight.

In case you need to restart Tomcat you need to restart the container itself. Logging into the container and restarting the tomcat7 process will not work since the container and not the process is linked to the MongoDB and ElasticSearch containers. Meaning if you restart the process only, tomcat will not have access to the mongo database and elastic search service.

### Mac OS X users

For now Docker needs Linux kernel to run on. For OS X the solution is to run Docker inside Linux VM. The instructions given at [Installation](https://docs.docker.com/installation/mac/) help setup working Docker installation using `boot2docker` application which in turn uses VBoxManage to initialize, start, stop and delete the VM right from the command line. In short we install the app from the package [download page](https://github.com/boot2docker/osx-installer/releases/download/v1.4.1/Boot2Docker-1.4.1.pkg) and run the following commands to initialize and run the VM:

```
$ boot2docker init
$ boot2docker up
$ $(boot2docker shellinit)
```

That's it, now we can continue setting up our development environment as described above. In short, first clone our Docker repo:

```
$ docker login
$ docker pull <my-user>/<my-repository>:elastic_search
$ docker pull <my-user>/<my-repository>:mongodb
$ docker pull <my-user>/<my-repository>:tomcat7
```

and when that's finished start the containers:

```
$ docker run -d --name="ElasticSearch" -t -i <my-user>/<my-repository>:elastic_search
$ docker run -d --name="MongoDB" -t -i <my-user>/<my-repository>:mongodb
$ docker run -d --name="Tomcat" --link MongoDB:db --link ElasticSearch:es -p 443:443 -t -i <my-user>/<my-repository>:tomcat7
```

then after waiting for couple of minutes for the tomcat container to start properly we can run:

```
$ open https://$(boot2docker ip 2>/dev/null)/
```

to start the browser and get access to the encompass login screen. To use the latest application deployed to our Amazon Devtest instance, open another terminal and download the war file into the VM:

```
tanyas-air:~ Guest$ sudo mkdir -p /opt/encompass/deploy
tanyas-air:~ Guest$ ssh $(boot2docker ip)
docker@boot2docker:~$ sudo cp encompass.war /opt/encompass/deploy/
```

before starting the tomcat container (replace the user name and password in the above command) in the first terminal:

```
tanyas-air:~ Guest$ docker run -d --name="Tomcat" --link MongoDB:db --link ElasticSearch:es -p 443:443 -v /opt/encompass/deploy:/opt/encompass/deploy -t -i <my-user>/<my-repository>:tomcat7
```

The above example is from a Mac I've setup a DEV environment on and bellow is a example of a successful connection to the Admin Portal running inside the container:

```
tanyas-air:~ Guest$ curl -k -s -S -I -H "Host: admin" https://$(boot2docker ip 2>/dev/null)/
HTTP/1.1 200 OK
Server: Apache-Coyote/1.1
Cache-Control: no-cache
Expires: Thu, 01 Jan 1970 00:00:00 GMT
Set-Cookie: JSESSIONID=A5D0C712445BE4AF9A62B58EEB28B7BA.app1-prod; Path=/; Secure; HttpOnly
Pragma: no-cache
Content-Type: text/html;charset=UTF-8
Content-Length: 2723
Vary: Accept-Encoding
Date: Mon, 22 Dec 2014 00:47:34 GMT
```

The full print of the docker containers running on the laptop:

```
tanyas-air:~ Guest$ docker ps
CONTAINER ID        IMAGE                                      COMMAND             CREATED             STATUS              PORTS                                                      NAMES
f0a71a98aa2b        <my-user>/<my-repository>:tomcat7          "/bin/bash"         About an hour ago   Up About an hour    8999/tcp, 22/tcp, 80/tcp, 8998/tcp, 0.0.0.0:443->443/tcp   Tomcat             
d4617ecba24f        <my-user>/<my-repository>:mongodb          "/bin/bash"         2 days ago          Up 2 days           28018/tcp, 22/tcp, 27017/tcp, 27018/tcp, 28017/tcp         MongoDB            
abdaf02dd2c2        <my-user>/<my-repository>:elastic_search   "/bin/bash"         2 days ago          Up 2 days           22/tcp, 9200/tcp                                           ElasticSearch
```

Maybe it is useful to mention here that this is exactly the same process that Vagrant for example goes through on OS-X, it starts a VM via `boot2docker` application wrapper.

## Deploying/Redeploying Encompass In Docker Containers

One feature that can come handy for local deployment are the `Data Volumes`. They can be attached to the container on runtime and they can be any file or directory from the host's own file system. For example we can start Tomcat from our last example above as:

```
$ sudo docker run -d --name="Tomcat" --link MongoDB:db --link ElasticSearch:es -p 443:443 -v /opt/encompass/deploy:/opt/encompass/deploy -t -i <my-user>/<my-repository>:tomcat7
```

This will mount `/opt/encompass/deploy` on the Docker host to `/opt/encompass/deploy` inside the container. Meaning we can just drop our new Encompass (or Admin) war file in this directory and run a container to deploy our new code.  Multiple directories can be mounted on run time via multiple `-v` switches. Obviously the war file should have consistent name so we don't have to ever touch Tomcat's descriptors, for example `encompass.war` and `admin.war`. Even more, the `Data Volumes` can be shared between containers using `--volumes-from` switch and can also be used for backup and recovery.

In case we want to update the the currently running application with new one, without the need to go through the process of building a new container image, first we copy the new version we obtained from our Github repository into the shared storage and restart the container:

```
$ sudo cp new-encompass.war /opt/encompass/deploy/encompass.war
$ sudo docker stop Tomcat
$ sudo docker start Tomcat
```

where Tomcat is the name of our tomcat container.

## Issues and Troubleshooting

After playing around, destroying and creating several Tomcat containers, I noticed the Encompass application suddenly could not be accessed via internet any more. The investigation pointed to the following problem:

```
root@ip-172-31-1-215:~# iptables -nvL DOCKER -t nat
Chain DOCKER (2 references)
 pkts bytes target     prot opt in     out     source               destination        
   26  1560 DNAT       tcp  --  !docker0 *       0.0.0.0/0            0.0.0.0/0            tcp dpt:443 to:172.17.0.14:443
    0     0 DNAT       tcp  --  !docker0 *       0.0.0.0/0            0.0.0.0/0            tcp dpt:443 to:172.17.0.16:443
```

We can see here two identical firewall rules redirecting the SSL traffic to two different Tomcat containers. In cases like this, only the first one is in power. The problem is that the container the traffic was being sent to, the one with IP of 172.17.0.14, was not active any more, in fact it was deleted. I have no idea how did this happen and what is the cause of it but obviously it failed to get removed upon deletion of the previous Tomcat container or maybe was saved like that during firewall upgraded and then restored. Removing the rouge firewall rule fixed the issue and the application was available again:

```
root@ip-172-31-1-215:~# iptables -D DOCKER 1 -t nat
```