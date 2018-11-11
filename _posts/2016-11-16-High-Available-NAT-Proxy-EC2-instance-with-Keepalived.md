---
type: posts
header:
  teaser: 'images.jpg'
title: 'Highly Available NAT/Proxy EC2 instance with Keepalived'
categories: 
  - High-Availability
tags: ['aws','high-availability','keepalived']
date: 2016-11-16
---

The two EC2 instances we are using as GW are launched in different AZ's and are running Ubuntu-16.04. Each instance has one primary and one secondary IP attached to eth0 interface. The primary provides public access to the instance and the secondary will be used to attach the VIP1 (EIP) that will be shared between the instances in the public subnet. In this way the instance that does not hold the VIP will still have it's own public IP and be accessible externally. They also have eth1 interface connected to the private subnet of the VPC. This interface will get the second, private, VIP2 attached to which all private instances will use as default GW. The setup looks like this:


```
   --------------------------------------------------- internet
       |                    WAN                  |
       |                                         |
       |              VIP1:34.xxx.xxx.xxx        |
   eth0|10.77.0.233                          eth0|10.77.1.53 
    -------                                   -------
    | gw1 |                                   | gw2 |
    -------                                   -------
   eth1|10.77.3.220                          eth1|10.77.4.53
       |              VIP2:10.240.240.240        |
       |                                         |
       |                    LAN                  |
   --------------------------------------------------- 10.77.3.0/24, 10.77.4.0/24
```

This is how the eth1 interface looks on the first instance when it owns the VIP2 address:

```
root@ip-10-77-0-233:~# ip -4 a s dev eth1
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    inet 10.77.3.220/24 brd 10.77.3.255 scope global eth1
       valid_lft forever preferred_lft forever
    inet 10.240.240.240/32 scope global eth1
       valid_lft forever preferred_lft forever
```

The second one will only have it's primary address:

```
root@ip-10-77-1-53:~# ip -4 a s eth1
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    inet 10.77.4.53/24 brd 10.77.4.255 scope global eth1
       valid_lft forever preferred_lft forever
```

The VIP2 can be any arbitrary private address and that is because we update the Routing Tables for all private subnets with a record pointing to the IP of the GW instance that owns it atm. This is done via the fail-over script shown below.
 
This is the `Keepalived` config file `/etc/keepalived/keepalived.conf` on the first GW instance:

```
global_defs {
    lvs_flush             # flush any existing LVS configuration at startup
    vrrp_version 2        # 2 or 3, default version 2
    vrrp_iptables
    vrrp_check_unicast_src
    vrrp_priority -20
    checker_priority -20
    vrrp_no_swap
    checker_no_swap
}

vrrp_instance I1 {
    interface eth1
    state BACKUP
    virtual_router_id 69
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass password
    }
    unicast_src_ip 10.77.3.220 
    unicast_peer {
        10.77.4.53
    }
    virtual_ipaddress {
        10.240.240.240/32 dev eth1
    }
    nopreempt
    debug 4
    garp_master_delay 3
    garp_master_repeat 3
    garp_lower_prio_delay 10
    garp_lower_prio_repeat 1
    garp_master_refresh 60
    garp_master_refresh_repeat 2

    notify_master "/etc/keepalived/primary-backup.sh primary 34.xxx.xxx.xxx 10.240.240.240"
    notify_backup "/etc/keepalived/primary-backup.sh backup"
}
```

The config on the other instance will look similar:

```
global_defs {
    lvs_flush             # flush any existing LVS configuration at startup
    vrrp_version 2        # 2 or 3, default version 2
    vrrp_iptables
    vrrp_check_unicast_src
    vrrp_priority -20
    checker_priority -20
    vrrp_no_swap
    checker_no_swap
}

vrrp_instance I1 {
    interface eth1
    state BACKUP
    virtual_router_id 69
    priority 50
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass password
    }
    unicast_src_ip 10.77.4.53
    unicast_peer {
        10.77.3.220
    }
    virtual_ipaddress {
        10.240.240.240/32 dev eth1
    }
    nopreempt
    debug 4
    garp_master_delay 3
    garp_master_repeat 3
    garp_lower_prio_delay 10
    garp_lower_prio_repeat 1
    garp_master_refresh 60
    garp_master_refresh_repeat 2

    notify_master "/etc/keepalived/primary-backup.sh primary 34.xxx.xxx.xxx 10.240.240.240"
    notify_backup "/etc/keepalived/primary-backup.sh backup"
}
```

The fail-over script `/etc/keepalived/primary-backup.sh`:

```bash 
#!/bin/bash
. /lib/lsb/init-functions

function log { logger -t "vpc" -- $1; }

function die {
  [ -n "$1" ] && log "$1"
  log "Configuration of EIP/VIP failover failed!"
  exit 1
}

ELASTIC_IP=$2
PRIVATE_VIP=$3

URL="http://169.254.169.254/latest"

log "Determining the MAC address on eth0..."
ETH0_MAC=$(cat /sys/class/net/eth0/address) ||
    die "Unable to determine MAC address on eth0."
log "Found MAC ${ETH0_MAC} for eth0."

log "Determining the MAC address on eth1..."
ETH1_MAC=$(cat /sys/class/net/eth1/address) ||
    die "Unable to determine MAC address on eth1."
log "Found MAC ${ETH1_MAC} for eth1."

# CLI read and connect timeouts so we don't wait forever
AWS_CLI_PARAMS="--cli-read-timeout 3 --cli-connect-timeout 2"

# Set CLI Output to text
export AWS_DEFAULT_OUTPUT="text"

# Collect instance data
ii=$(curl -s $URL/dynamic/instance-identity/document | grep -v -E "{|}" | sed 's/[ \t"]//g;s/,$//')

# Set region of the instance
REGION=$(echo "$ii" | grep region | cut -d":" -f2)

# Set AWS CLI default Region
export AWS_DEFAULT_REGION=$REGION

# Set AZ of the instance
AVAILABILITY_ZONE=$(echo "$ii" | grep availabilityZone | cut -d":" -f2)

# Set Instance ID from metadata
INSTANCE_ID=$(echo "$ii" | grep instanceId | cut -d":" -f2)

# Set Instance main IP from metadata
IP_ETH0=$(echo "$ii" | grep privateIp | cut -d":" -f2)

# Find the eth0 secondary IP
IP_ETH0_SEC=""
IPV4S_ETH0=$(curl -s $URL/meta-data/network/interfaces/macs/${ETH0_MAC}/local-ipv4s)
log "Determining the secondary private IP of eth0..."
for i in $(echo $IPV4S_ETH0); do
  [[ "$i" != "$IP_ETH0" ]] && { IP_ETH0_SEC="$i"; break; } 
done
[[ "$IP_ETH0_SEC" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  && log "Found secondary IP of $IP_ETH0_SEC for eth0." \
  || die "Failed to find the secondary private IP of eth0."

# Find the eth0 ENI 
log "Determining the ENI of eth0..."
ENI_ETH0=$(curl -s $URL/meta-data/network/interfaces/macs/${ETH0_MAC}/interface-id) \
  && log "Found ENI of $ENI_ETH0 for eth0." \
  || die "Failed to find the ENI for eth0."

# Find the eth1 ENI 
log "Determining the ENI of eth1..."
ENI_ETH1=$(curl -s $URL/meta-data/network/interfaces/macs/${ETH1_MAC}/interface-id) \
  && log "Found ENI of $ENI_ETH1 for eth1." \
  || die "Failed to find the ENI for eth1."

# EIP Allocation ID
log "Determining the AllocationId for $ELASTIC_IP..."
ALOC_ID=$(aws ec2 describe-addresses $AWS_CLI_PARAMS \
  --public-ips $ELASTIC_IP --query 'Addresses[0].AllocationId' --output text) \
  && log "Found AllocationId of $ALOC_ID for $ELASTIC_IP" \
  || die "Failed to find the AllocationId for $ELASTIC_IP."

# Set VPC_ID of Instance
VPC_ID=$(aws ec2 describe-instances $AWS_CLI_PARAMS \
  --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].VpcId') \
  || die "Unable to determine VPC ID for instance."

case $1 in
    primary)
        log "Taking over EIP $ELASTIC_IP ownership..."
        aws ec2 associate-address --allocation-id $ALOC_ID \
        --network-interface-id $ENI_ETH0 \
        --private-ip-address $IP_ETH0_SEC \
        --allow-reassociation 2>/dev/null \
        || die "Unable to associate the EIP $ELASTIC_IP with the instance."

        # Get list of subnets in same VPC that have tag Network=private
        PRIVATE_SUBNETS="$(aws ec2 describe-subnets --query 'Subnets[*].SubnetId' \
        --filters Name=vpc-id,Values=$VPC_ID Name=state,Values=available Name=tag:Network,Values=private)"

        # If no private subnets found, exit
        if [ -z "$PRIVATE_SUBNETS" ]; then
          die "No private subnets found to modify."
        else 
          log "Modifying Route Tables for following private subnets: $PRIVATE_SUBNETS"
        fi

        for subnet in $PRIVATE_SUBNETS; do
          ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
          --query 'RouteTables[*].RouteTableId' \
          --filters Name=association.subnet-id,Values=$subnet);
          # If private tagged subnet is associated with Main Routing Table, do not create or modify route.
          if [[ "$ROUTE_TABLE_ID" == "$MAIN_RT" ]]; then
            log "$subnet is associated with the VPC Main Route Table. The script will NOT edit Main Route Table."
          # If subnet is not associated with a Route Table, skip it.
          elif [[ -z "$ROUTE_TABLE_ID" ]]; then
            log "$subnet is not associated with a Route Table. Skipping this subnet."
          else
            # Modify found private subnet's Routing Table to point to the private fail-over VIP
            aws ec2 create-route --route-table-id $ROUTE_TABLE_ID \
            --destination-cidr-block ${PRIVATE_VIP}/32 \
            --network-interface-id $ENI_ETH1 2>/dev/null \
            && log "Route created in $ROUTE_TABLE_ID pointing ${PRIVATE_VIP}/32 to interface with ID $ENI_ETH1."
            if [[ $? -ne 0 ]] ; then
              log "Route already exists, replacing existing route."
              aws ec2 replace-route --route-table-id $ROUTE_TABLE_ID \
              --destination-cidr-block ${PRIVATE_VIP}/32 \
              --network-interface-id $ENI_ETH1 2>/dev/null \
              && log "$ROUTE_TABLE_ID modified to point ${PRIVATE_VIP}/32 to interface with ID $ENI_ETH1."
            fi
          fi
        done

        log "Primary VIP config finished."
       ;;
    backup)
        log "Transitioned into backup state."
       ;;
    status)
        id=$(aws ec2 describe-addresses --public-ips $ELASTIC_IP --query 'Addresses[0].InstanceId' --output text) 
        [[ $? -eq 0 ]] && [[ "$id" =~ ^i-[A-Fa-f0-9]{8,20}$ ]] && echo OK || echo FAIL
        ;;
esac

exit 0
```

Basically with each fail-over we associate the VIP1 (EIP) with the secondary IP of the eth0's ENI interface. Then we search for all private subnets in our VPC that we have tagged with `Network=private` and update their Routing Tables for the VIP2 address.

The GW instances need the following IAM instance role assigned in order to manipulate the EC2 resources:

```
IAM role needed for the instances:

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces",
        "ec2:ModifyInstanceAttribute",
        "ec2:DescribeSubnets",
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:ReplaceRoute",
        "ec2:AllocateAddress",
        "ec2:AssignPrivateIpAddresses",
        "ec2:AssociateAddress",
        "ec2:DescribeAddresses",
        "ec2:DisassociateAddress"
      ],
      "Resource": "*"
    }
  ]
}
```

They also need IP forwarding enabled which means the following system kernel parameter set `net.ipv4.ip_forward = 1`.

The clients will have the VIP2 `10.240.240.240` set as default GW. To test we run `wget` on the client to start downloading some large file like iso image:

```
root@ip-10-77-3-92:~# wget -O/dev/null 'http://194.71.11.173/debian-cd/9.2.1/amd64/iso-dvd/debian-9.2.1-amd64-DVD-1.iso'
...
HTTP request sent, awaiting response... 200 OK
Length: 3964551168 (3.7G) [application/x-iso9660-image]
Saving to: ‘/dev/null’

38% [================================================================>                        ] 1,533,365,098 19.1MB/s  eta 2m 2s 
```

Then force fail-over in the cluster by stopping Keepalived on the Primary:

```
root@ip-10-77-1-53:~# service keepalived stop
```

and monitor the log of the peer server to confirm it's becoming Primary:

```
root@ip-10-77-0-233:~# systemctl status -l keepalived.service 
 keepalived.service - LSB: Starts keepalived
   Loaded: loaded (/etc/init.d/keepalived; bad; vendor preset: enabled)
   Active: active (running) since Tue 2016-11-07 06:06:13 UTC; 6 days ago
     Docs: man:systemd-sysv-generator(8)
  Process: 52035 ExecStop=/etc/init.d/keepalived stop (code=exited, status=0/SUCCESS)
  Process: 52077 ExecStart=/etc/init.d/keepalived start (code=exited, status=0/SUCCESS)
    Tasks: 3
   Memory: 5.9M
      CPU: 1min 471ms
   CGroup: /system.slice/keepalived.service
           ├─52084 /usr/sbin/keepalived
           ├─52086 /usr/sbin/keepalived
           └─52087 /usr/sbin/keepalived

Nov 13 23:12:25 ip-10-77-0-233 vpc[68924]: rtb-96xxxxf1 modified to point 10.240.240.240/32 to interface with ID eni-51xxxx7b.
Nov 13 23:12:26 ip-10-77-0-233 vpc[68933]: Route already exists, replacing existing route.
Nov 13 23:12:26 ip-10-77-0-233 vpc[68938]: rtb-08xxxx6f modified to point 10.240.240.240/32 to interface with ID eni-51xxxx7b.
Nov 13 23:12:27 ip-10-77-0-233 vpc[68947]: Route already exists, replacing existing route.
Nov 13 23:12:28 ip-10-77-0-233 vpc[68958]: rtb-95xxxxf2 modified to point 10.240.240.240/32 to interface with ID eni-51xxxx7b.
Nov 13 23:12:30 ip-10-77-0-233 vpc[68969]: Route already exists, replacing existing route.
Nov 13 23:12:30 ip-10-77-0-233 vpc[68974]: rtb-91xxxxf6 modified to point 10.240.240.240/32 to interface with ID eni-51xxxx7b.
Nov 13 23:12:31 ip-10-77-0-233 vpc[68983]: Route already exists, replacing existing route.
Nov 13 23:12:32 ip-10-77-0-233 vpc[68988]: rtb-97xxxxf0 modified to point 10.240.240.240/32 to interface with ID eni-51xxxx7b.
Nov 13 23:12:32 ip-10-77-0-233 vpc[68989]: Primary VIP config finished.
```

we can see this server taking over the IP's and updating the routing table. In the mean time the wget on the client is still running uninterrupted. We start the Keepalived instance on the previous Master:

```
root@ip-10-77-1-53:~# service keepalived start
```

and force another failover:

```
root@ip-10-77-0-233:~# systemctl stop keepalived.service 
root@ip-10-77-0-233:~# systemctl status -l keepalived.service 
 keepalived.service - LSB: Starts keepalived
   Loaded: loaded (/etc/init.d/keepalived; bad; vendor preset: enabled)
   Active: inactive (dead) since Mon 2016-11-13 23:13:44 UTC; 3s ago
     Docs: man:systemd-sysv-generator(8)
  Process: 68994 ExecStop=/etc/init.d/keepalived stop (code=exited, status=0/SUCCESS)
  Process: 52077 ExecStart=/etc/init.d/keepalived start (code=exited, status=0/SUCCESS)
    Tasks: 0
   Memory: 5.1M
      CPU: 1min 484ms

Nov 13 23:12:32 ip-10-77-0-233 vpc[68989]: Primary VIP config finished.
Nov 13 23:13:44 ip-10-77-0-233 systemd[1]: Stopping LSB: Starts keepalived...
Nov 13 23:13:44 ip-10-77-0-233 keepalived[68994]:  * Stopping keepalived keepalived
Nov 13 23:13:44 ip-10-77-0-233 Keepalived[52084]: Stopping
Nov 13 23:13:44 ip-10-77-0-233 Keepalived_vrrp[52087]: VRRP_Instance(I1) sent 0 priority
Nov 13 23:13:44 ip-10-77-0-233 Keepalived_healthcheckers[52086]: Stopped
Nov 13 23:13:44 ip-10-77-0-233 keepalived[68994]:    ...done.
Nov 13 23:13:44 ip-10-77-0-233 systemd[1]: Stopped LSB: Starts keepalived.
Nov 13 23:13:45 ip-10-77-0-233 Keepalived_vrrp[52087]: Stopped
Nov 13 23:13:45 ip-10-77-0-233 Keepalived[52084]: Stopped Keepalived v1.2.23 (07/26,2016)
```

and monitor the takeover on the new Primary:

```
root@ip-10-77-1-53:~# systemctl status -l keepalived.service 
 keepalived.service - LSB: Starts keepalived
   Loaded: loaded (/etc/init.d/keepalived; bad; vendor preset: enabled)
   Active: active (running) since Mon 2016-11-13 23:13:13 UTC; 1min 0s ago
     Docs: man:systemd-sysv-generator(8)
  Process: 130125 ExecStop=/etc/init.d/keepalived stop (code=exited, status=0/SUCCESS)
  Process: 130168 ExecStart=/etc/init.d/keepalived start (code=exited, status=0/SUCCESS)
    Tasks: 3
   Memory: 10.4M
      CPU: 9.422s
   CGroup: /system.slice/keepalived.service
           ├─130175 /usr/sbin/keepalived
           ├─130177 /usr/sbin/keepalived
           └─130178 /usr/sbin/keepalived

Nov 13 23:13:54 ip-10-77-1-53 vpc[130295]: rtb-96xxxxf1 modified to point 10.240.240.240/32 to interface with ID eni-2fxxxx13.
Nov 13 23:13:55 ip-10-77-1-53 vpc[130304]: Route already exists, replacing existing route.
Nov 13 23:13:56 ip-10-77-1-53 vpc[130309]: rtb-08xxxx6f modified to point 10.240.240.240/32 to interface with ID eni-2fxxxx13.
Nov 13 23:13:57 ip-10-77-1-53 vpc[130318]: Route already exists, replacing existing route.
Nov 13 23:13:57 ip-10-77-1-53 vpc[130323]: rtb-95xxxxf2 modified to point 10.240.240.240/32 to interface with ID eni-2fxxxx13.
Nov 13 23:13:58 ip-10-77-1-53 vpc[130332]: Route already exists, replacing existing route.
Nov 13 23:13:58 ip-10-77-1-53 vpc[130337]: rtb-91xxxxf6 modified to point 10.240.240.240/32 to interface with ID eni-2fxxxx13.
Nov 13 23:13:59 ip-10-77-1-53 vpc[130348]: Route already exists, replacing existing route.
Nov 13 23:14:00 ip-10-77-1-53 vpc[130353]: rtb-97xxxxf0 modified to point 10.240.240.240/32 to interface with ID eni-2fxxxx13.
Nov 13 23:14:00 ip-10-77-1-53 vpc[130354]: Primary VIP config finished.
```

while confirming the download has still not been interrupted on the client.