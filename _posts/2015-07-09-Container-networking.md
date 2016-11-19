---
type: posts
header:
  teaser: 'docker1.png'
title: 'Container Networking'
categories: 
  - Docker
tags: [docker, containers, virtualizasion]
---

The previous related post [Building custom Docker images and configuring with Ansible]({{ site.baseurl }}{% post_url 2015-07-09-Building-custom-Docker-images-and-configuring-with-Ansible %}) talked about creating our own customized images and running our application in containers built from those images pulled from our private DockerHub repository we created.

Now that we have our containers running we need to get their services connect to each other. The default Docker networking consist of single virtual bridge where all containers created connect to via their default interface `eth0`. The problem here is that the IP addresses for the containers on this network are randomly issued via Docker internal DHCP service and there isn't any native way inside Docker to assign static ones. This is not a problem by itself since the containers will be able to see each other via the bridge. The problem is that there is no way to know the IP addresses in front during our automated image creation process thus we can't tell Tomcat where to find the DB and ES servers in our Ansible playbooks. If we want to muck around with the containers on our local hosts then this is fine, but most of the users would probably want to just pull the images and start the containers and everything should just work.

Therefor we need to do some preparation first on the host we want ro run these containers on ie our local station. We have the following options.

## Port Mapping

We can map the container ports to the host ports on start up and make the container ports appear on the host as well. In case of the Tomcat container as example we could do the following:

```
$ sudo docker run -d --name="ElasticSearch" -p 9200:9200 -p 9300:9300 -t -i encompass/elastic_search:latest
$ sudo docker run -d --name="MongoDB" -p 27017:27017 -p 27018:27018 -t -i encompass/mongodb:latest
$ sudo docker run -d --name="Tomcat" -p 80:80 -p 443:443 -t -i encompass/tomcat7:latest
```

Then we can set Tomcat to connect to MongoDB and ES on the host IP address which we know in front and assume is static. Still, since more then one user in different networks with different IP's will use the images we can't use this approach reliably. It also constrains us to only one container on specific port.

## Container Linking

Docker has a linking system that allows us to link multiple containers together and send connection information from one to another. When containers are linked, information about a source container can be sent to a recipient container. This allows the recipient to see selected data describing aspects of the source container. These information appears on the target in the form of environment variables and its hosts file gets updated with the source details. For us this means that we can start the Tomcat container and link it to the already running MongoDB and ES ones, for example:

```
$ sudo docker run -d --name="ElasticSearch" -t -i encompass/elastic_search:latest
$ sudo docker run -d --name="MongoDB" -t -i encompass/mongodb:latest
$ sudo docker run -d --name="Tomcat" --link MongoDB:db --link ElasticSearch:es -t -i encompass/tomcat7:latest
```

Now when Tomcat container starts we can see the following environment variables inside if we run the `env` command:

```
...
DB_PORT_27017_TCP_PORT=27017
DB_PORT_27018_TCP_PORT=27018
DB_PORT_27017_TCP_ADDR=172.17.0.123
ES_PORT_9200_TCP_PORT=9200
ES_PORT_9200_TCP_ADDR=172.17.0.122
...
```

Now knowing in front that this is the way we are always going to start our containers, then we can use this variables in our Ansible playbooks. For example we can use in Tomcat configuration file:

```
JAVA_OPTS="${JAVA_OPTS} -Des.cluster.name=encsearchdb -Des.node.hosts=${ES_PORT_9200_TCP_ADDR}"
JAVA_OPTS="${JAVA_OPTS} -Ddb.encompass.hosts=${DB_PORT_27017_TCP_ADDR}:27017 -Ddb.audit.hosts=${DB_PORT_27018_TCP_ADDR}:27018"
```

and make our images generic. This is fairly simple approach, tested and works fine. I have adopted this one for building our Tomcat image and running the container.

## Pipework

The third option would be assigning static IP to a container outside of Docker using veth pair of interfaces and netns option of the ip tool. The process for our Tomcat container would be as follows:

```bash
$ sudo aptitude install bridge-utils arping
 
$ IFNAME=docker0
$ CONTAINER_IFNAME=eth1
$ IPADDR=172.17.0.201/16
$ GUESTNAME="Tomcat"
 
$ MTU=$(ip link show docker0 | awk '{print $5}')
{% raw %}
$ NSPID=$(docker inspect --format='{{ .State.Pid }}' $GUESTNAME)
{% endraw %}
$ LOCAL_IFNAME="v${CONTAINER_IFNAME}pl${NSPID}"
$ GUEST_IFNAME="v${CONTAINER_IFNAME}pg${NSPID}"
 
# set the host side of the pair
$ sudo ip link add name $LOCAL_IFNAME mtu $MTU type veth peer name $GUEST_IFNAME mtu $MTU
$ sudo brctl addif $IFNAME $LOCAL_IFNAME
$ sudo ip link set $LOCAL_IFNAME up
 
# set the container side of the pair
$ sudo ip link set $GUEST_IFNAME netns $NSPID
$ sudo ip netns exec $NSPID ip link set dev $GUEST_IFNAME name $CONTAINER_IFNAME
$ sudo ip netns exec $NSPID ip addr add $IPADDR dev $CONTAINER_IFNAME
$ sudo ip netns exec $NSPID ip link set $CONTAINER_IFNAME up
$ sudo ip netns exec $NSPID arping -c 1 -A -I $CONTAINER_IFNAME $IPADDR
```

In other words, after installing the needed software, we create a pair of veth interfaces on the host and attach one end to the container and the other end to Docker's docker0 bridge. Then we set a static IP address from docker0 IP range using netns directly in the virtual network space of the container and finally do an ARP broadcast on the containers network to inform the other peers of the new interface.

Now, all this can be automated using the pipework shell script that does all this for us automatically:

```
$ TOMCAT=$(sudo docker run -d --name="Tomcat" -t -i encompass/tomcat7:latest)
$ sudo pipework docker0 $TOMCAT 172.17.0.201/16
```

This will create interface `eth1` inside the container and assign the specified IP. This has not be tested and can not confirm it is working across various platforms apart from Linux.

## Connecting Docker Containers Running On Different Hosts

This is more of a demonstration of how we can link containers running on different hosts and bring them into same Docker network. Will be using `OVS V-Switch` and `GRE tunnel` between the hosts for this purpose. I have two Docker hosts each running our three containers. On both of them we install the needed packages:

```
$ sudo aptitude install bridge-utils openvswitch-common openvswitch-switch
```
GRE adds some encapsulation overhead so first thing we need to do is increase the MTU on the tunnel interface from the default of 1500:

```
$ sudo ifconfig eth0 mtu 1542
```

Then we setup our GRE tunnel and attach it to the existing Docker bridge docker0:

```
ubuntu@ip-172-31-1-215:~$ sudo ovs-vsctl add-br br0
ubuntu@ip-172-31-1-215:~$ sudo ovs-vsctl add-port br0 gre0 -- set interface gre0 type=gre options:remote_ip=172.31.7.240
ubuntu@ip-172-31-1-215:~$ sudo brctl addif docker0 br0
```

The result should be:

```
ubuntu@ip-172-31-1-215:~$ brctl show
bridge name bridge id       STP enabled interfaces
docker0     8000.56847afe9799   no      br0
                            veth646e45b
                            vethd0be9bd
                            vethfa3e116
 
ubuntu@ip-172-31-1-215:~$ sudo ovs-vsctl show
6ec4b0ba-f2a4-482d-8ff1-d5d620a75569
    Bridge "br0"
        Port "gre0"
            Interface "gre0"
                type: gre
                options: {remote_ip="172.31.7.240"}
        Port "br0"
            Interface "br0"
                type: internal
    ovs_version: "2.0.2"
```

We do the same for the second host just changing the target ip of the other host:

```
ubuntu@ip-172-31-7-240:~$ sudo ovs-vsctl add-br br0
ubuntu@ip-172-31-7-240:~$ sudo ovs-vsctl add-port br0 gre0 -- set interface gre0 type=gre options:remote_ip=172.31.1.215
ubuntu@ip-172-31-7-240:~$ sudo brctl addif docker0 br0
```

and we should see:

```
ubuntu@ip-172-31-7-240:~$ brctl show
bridge name bridge id       STP enabled interfaces
docker0     8000.56847afe9799   no      br0
                            veth07fced9
                            veth1004d6c
                            veth63474e1
 
ubuntu@ip-172-31-7-240:~$ sudo ovs-vsctl show
ac8ad635-f2ff-4562-8138-4f58783cd7fc
    Bridge "br0"
        Port "br0"
            Interface "br0"
                type: internal
        Port "gre0"
            Interface "gre0"
                type: gre
                options: {remote_ip="172.31.1.215"}
    ovs_version: "2.0.2"
```

On the first box the Docker IP's of our containers are:

```
ubuntu@ip-172-31-1-215:~/ansible_docker$ for cont in $(sudo docker ps -q); do sudo docker inspect --format '{{ .NetworkSettings.IPAddress }}' $cont; done
172.17.0.4
172.17.0.3
172.17.0.2
```

and on the second one our Tomcat container for example has IP of:

```
{% raw %}
ubuntu@ip-172-31-7-240:~$ sudo docker inspect --format '{{ .NetworkSettings.IPAddress }}' cc7088477bf7
172.17.0.5
{% endraw %}
```

Now if I attach to any of the the first box containers I should be able to ping the Tomcat on the second box:

```
ubuntu@ip-172-31-1-215:~$ sudo docker attach 7c324784405d
root@7c324784405d:~# ping -c 4 172.17.0.5
PING 172.17.0.5 (172.17.0.5) 56(84) bytes of data.
64 bytes from 172.17.0.5: icmp_seq=1 ttl=64 time=0.973 ms
64 bytes from 172.17.0.5: icmp_seq=2 ttl=64 time=0.537 ms
64 bytes from 172.17.0.5: icmp_seq=3 ttl=64 time=0.516 ms
64 bytes from 172.17.0.5: icmp_seq=4 ttl=64 time=0.627 ms
--- 172.17.0.5 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 2999ms
rtt min/avg/max/mdev = 0.516/0.663/0.973/0.184 ms
```

One drowback though is that since Docker randomly issues IP addresses to the containers running on its host, we might have a situation where containers on different hosts have same IP address. In that case this is not going to work and only solution I can see is terminating the container on one of the hosts and creating new one thus forcing Docker to re-issue new IP for it.

In case we want to add another Docker host to our network we create new GRE device for that host and enable STP on the bridge:

```
$ sudo ovs-vsctl set bridge br0 stp_enable=true
$ sudo ovs-vsctl add-port br0 gre1 -- set interface gre1 type=gre options:remote_ip=$THIRD_HOST_IP
```

Of course the tunnel needs to be established on the new host as well.
