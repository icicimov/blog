---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes shared block storage with external GlusterFS backend'
categories: 
  - Virtualization
tags: [kubernetes, docker, containers]
date: 2017-4-16
series: "Kubernetes Cluster in AWS"
excerpt: "There are many options available in Kubernetes when it comes to shared storage. I'm using here a GlusterFS cluster as backend for the shared storage in a k8s cluster in AWS utilizing the RESTful API provided by Heketi."
---

This approach uses a GlusterFS (v3.8.12 on Ubuntu-14.04 VM's) cluster storage external to Kubernetes. It has benefits of dynamic volume provisioning via the Kubernetes built-in GlusterFS provisioning driver. [Heketi](https://github.com/heketi/heketi) project makes it possible to provision and maintain GlusterFS volumes via RESTful API and provides the glue between Kubernetes and GlusterFS.

Kubernetes already provides persistent block volumes to the hosted services via the built-in AWS EBS storage class. However, once this kind of EBS backed PV (Peristent Volume) gets attached to a k8s node a Pod using it is running on, it will stay attached to that node only and can not be shared across multiple Pods and k8s nodes. Furthermore, if the node the Pod is running on dies and can not be replaced with a new one in the same zone, the Pod will get moved to another node in the cluster and if that node is not in the same AZ (Availability Zone) the EBS volume will not move with it. These are some of the problems that using GlusterFS provided block storage will solve for us.

# Heketi Setup

Install Heketi on one of the GlusterFS nodes, the project does not provide `.deb` packages (only rpm) so we need to install via tarball:

```
# wget https://github.com/heketi/heketi/releases/download/v4.0.0/heketi-v4.0.0.linux.amd64.tar.gz
# tar xzvf heketi-v4.0.0.linux.amd64.tar.gz
# cd heketi
# cp heketi heketi-cli /usr/local/bin/
# heketi -v
Heketi v4.0.0
```

We also need to manually create the heketi user and the directory structures for the configuration:

```
# groupadd -r -g 515 heketi
# useradd -r -c "Heketi user" -d /var/lib/heketi -s /bin/false -m -u 515 -g heketi heketi
# mkdir -p /var/lib/heketi && chown -R heketi:heketi /var/lib/heketi
# mkdir -p /var/log/heketi && chown -R heketi:heketi /var/log/heketi
# mkdir -p /etc/heketi
```

Heketi has several provisioners and I'll be using the `ssh` one, thus need to setup password-less ssh login between the gluster nodes so heketi can access them and issue gluster commands as root user:

```
root@glustera:~# ssh-keygen -f /etc/heketi/heketi_key -t rsa -N ''
root@glustera:~# chown heketi:heketi /etc/heketi/heketi_key*
root@glustera:~# ssh-copy-id -i /etc/heketi/heketi_key.pub root@[glustera|glusterb|glusterc]
```

Configure ssh `/etc/ssh/sshd_config` on each of the gluster hosts to allow root login from the private subnet only:

```
[...]
Match User root
Match Address 10.99.0.0/20,127.0.0.1
PermitRootLogin yes
```

and restart the service. Test the password-less connectivity for the root user to the other nodes in the cluster:

```
root@glustera:~ ssh -i /etc/heketi/heketi_key root@glustera
root@glustera:~ ssh -i /etc/heketi/heketi_key root@glusterb
root@glustera:~ ssh -i /etc/heketi/heketi_key root@glusterc
```

Install the heketi config file, copy the example provided under `/opt/heketi/heketi.json` to `/etc/heketi/heketi.json` and edit it:

```
{
  "_port_comment": "Heketi Server Port Number",
  "port": "8080",
 
  "_use_auth": "Enable JWT authorization. Please enable for deployment",
  "use_auth": true,
 
  "_jwt": "Private keys for access",
  "jwt": {
    "_admin": "Admin has access to all APIs",
    "admin": {
      "key": "PASSWORD"
    },
    "_user": "User only has access to /volumes endpoint",
    "user": {
      "key": "PASSWORD"
    }
  },
 
  "_glusterfs_comment": "GlusterFS Configuration",
  "glusterfs": {
    "_executor_comment": [
      "Execute plugin. Possible choices: mock, ssh",
      "mock: This setting is used for testing and development.",
      "      It will not send commands to any node.",
      "ssh:  This setting will notify Heketi to ssh to the nodes.",
      "      It will need the values in sshexec to be configured.",
      "kubernetes: Communicate with GlusterFS containers over",
      "            Kubernetes exec api."
    ],
    "executor": "ssh",
 
    "_sshexec_comment": "SSH username and private key file information",
    "sshexec": {
      "keyfile": "/etc/heketi/heketi_key",
      "user": "root",
      "port": "22",
      "fstab": "/etc/fstab"
    },
 
    "_kubeexec_comment": "Kubernetes configuration",
    "kubeexec": {
      "host" :"https://kubernetes.host:8443",
      "cert" : "/path/to/crt.file",
      "insecure": false,
      "user": "kubernetes username",
      "password": "password for kubernetes user",
      "namespace": "OpenShift project or Kubernetes namespace",
      "fstab": "Optional: Specify fstab file on node.  Default is /etc/fstab"
    },
 
    "_db_comment": "Database file name",
    "db": "/var/lib/heketi/heketi.db",
    "brick_max_size_gb" : 1024,
    "brick_min_size_gb" : 1,
    "max_bricks_per_volume" : 33,
 
    "_loglevel_comment": [
      "Set log level. Choices are:",
      "  none, critical, error, warning, info, debug",
      "Default is warning"
    ],
    "loglevel" : "debug"
  }
}
```

The important part is the ssh provisioner where we setup the ssh key we created before. I installed systemd package and created the following Heketi service file `/etc/systemd/system/heketi.service`:

```
[Unit]
Description=Heketi Server
Requires=network-online.target
After=network-online.target
 
[Service]
Type=simple
User=heketi
Group=heketi
PermissionsStartOnly=true
PIDFile=/run/heketi/heketi.pid
Restart=on-failure
RestartSec=10
WorkingDirectory=/var/lib/heketi
RuntimeDirectory=heketi
RuntimeDirectoryMode=0755
ExecStartPre=[ -f "/run/heketi/heketi.pid" ] && /bin/rm -f /run/heketi/heketi.pid
ExecStart=/usr/local/bin/heketi --config=/etc/heketi/heketi.json
ExecReload=/bin/kill -s HUP $MAINPID
KillSignal=SIGINT
TimeoutStopSec=5
 
[Install]
WantedBy=multi-user.target
```

Start the service and check with journalctl:

```
root@glustera:~# systemctl daemon-reload
root@glustera:~# systemctl start heketi.service
root@glustera:~# journalctl -xe -u heketi
[...]
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: Heketi v4.0.0
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: [heketi] INFO 2017/05/24 14:35:27 Loaded ssh executor
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: [heketi] INFO 2017/05/24 14:35:27 Adv: Max bricks per volume set to 33
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: [heketi] INFO 2017/05/24 14:35:27 Adv: Max brick size 1024 GB
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: [heketi] INFO 2017/05/24 14:35:27 Adv: Min brick size 1 GB
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: [heketi] INFO 2017/05/24 14:35:27 Loaded simple allocator
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: [heketi] INFO 2017/05/24 14:35:27 GlusterFS Application Loaded
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: Authorization loaded
May 24 14:35:27 ip-10-99-3-216 heketi[8567]: Listening on port 8080
 
root@glustera:~# netstat -tuplen | grep LISTEN | grep heketi
tcp6       0      0 :::8080                 :::*                    LISTEN      515        322113      8567/heketi
```

Now we can enable the service accross restarts:

```
root@glustera:~# systemctl enable heketi
ln -s '/etc/systemd/system/heketi.service' '/etc/systemd/system/multi-user.target.wants/heketi.service'
```

Test the service from the local node:

```
root@glustera:~# curl http://glustera:8080/hello
Hello from Heketi
```

and remote node:

```
root@glusterb:~# curl http://glustera:8080/hello
Hello from Heketi
```

Also check that the authentication is working too:

```
root@glusterb:~# heketi-cli --server http://glustera:8080 --user admin --secret "PASSWORD" cluster list
Clusters:

```

## Heketi Topology

Now we need to tell Heketi about the topology of our GlusterFS cluster whcih consists of the following 3 hosts:

```
root@ip-10-99-3-216:/opt/heketi# host glustera
glustera.tftest.encompasshost.internal has address 10.99.3.216
root@ip-10-99-3-216:/opt/heketi# host glusterb
glusterb.tftest.encompasshost.internal has address 10.99.4.161
root@ip-10-99-3-216:/opt/heketi# host glusterc
glusterc.tftest.encompasshost.internal has address 10.99.5.91
```

We create the following `/etc/heketi/topology.json` config file:

```
{
  "clusters": [
    {
      "nodes": [
        {
          "node": {
            "hostnames": {
              "manage": [
                "glustera.tftest.encompasshost.internal"
              ],
              "storage": [
                "10.99.3.216"
              ]
            },
            "zone": 1
          },
          "devices": [
            "/dev/xvdf"
          ]
        },
        {
          "node": {
            "hostnames": {
              "manage": [
                "glusterb.tftest.encompasshost.internal"
              ],
              "storage": [
                "10.99.4.161"
              ]
            },
            "zone": 2
          },
          "devices": [
            "/dev/xvdf"
          ]
        },
        {
          "node": {
            "hostnames": {
              "manage": [
                "glusterc.tftest.encompasshost.internal"
              ],
              "storage": [
                "10.99.5.91"
              ]
            },
            "zone": 3
          },
          "devices": [
            "/dev/xvdf"
          ]
        }
      ]
    }
  ]
}
```

where `/dev/xvdf` is a 10GB raw block device attached to each gluster node. Then we load it:

```
root@ip-10-99-3-216:/opt/heketi# export HEKETI_CLI_SERVER=http://glustera:8080
root@ip-10-99-3-216:/opt/heketi# export HEKETI_CLI_USER=admin
root@ip-10-99-3-216:/opt/heketi# export HEKETI_CLI_KEY=PASSWORD
 
root@ip-10-99-3-216:/opt/heketi# heketi-cli topology load --json=/opt/heketi/topology.json
    Found node glustera.tftest.encompasshost.internal on cluster 37cc609c4ff862bfa69017747ea4aba4
        Adding device /dev/xvdf ... OK
    Found node glusterb.tftest.encompasshost.internal on cluster 37cc609c4ff862bfa69017747ea4aba4
        Adding device /dev/xvdf ... OK
    Found node glusterc.tftest.encompasshost.internal on cluster 37cc609c4ff862bfa69017747ea4aba4
        Adding device /dev/xvdf ... OK
 
root@ip-10-99-3-216:/opt/heketi# heketi-cli cluster list
Clusters:
37cc609c4ff862bfa69017747ea4aba4
 
root@ip-10-99-3-216:/opt/heketi# heketi-cli node list
Id:033b95c5a5a2ed6eabacea85dd9b7d83    Cluster:37cc609c4ff862bfa69017747ea4aba4
Id:6d24ec1a23a56a73eb03c4949a928e74    Cluster:37cc609c4ff862bfa69017747ea4aba4
Id:f1f4bf57f09a55847b89bbbe756ce1ac    Cluster:37cc609c4ff862bfa69017747ea4aba4
```

Test creation/deletion of volumes using `heketi-cli` tool we installed:

```
root@ip-10-99-3-216:/opt/heketi# heketi-cli volume create --size=1
Name: vol_3cc7ce25f5e7c441b64f56bff5a4fd7e
Size: 1
Volume Id: 3cc7ce25f5e7c441b64f56bff5a4fd7e
Cluster Id: 37cc609c4ff862bfa69017747ea4aba4
Mount: 10.99.3.216:vol_3cc7ce25f5e7c441b64f56bff5a4fd7e
Mount Options: backup-volfile-servers=10.99.4.161,10.99.5.91
Durability Type: replicate
Distributed+Replica: 3
 
root@ip-10-99-3-216:/opt/heketi# heketi-cli volume list
Id:3cc7ce25f5e7c441b64f56bff5a4fd7e    Cluster:37cc609c4ff862bfa69017747ea4aba4    Name:vol_3cc7ce25f5e7c441b64f56bff5a4fd7e
 
root@ip-10-99-3-216:/opt/heketi# gluster volume list
vol_3cc7ce25f5e7c441b64f56bff5a4fd7e
 
root@ip-10-99-3-216:/opt/heketi# gluster volume info vol_3cc7ce25f5e7c441b64f56bff5a4fd7e
Volume Name: vol_3cc7ce25f5e7c441b64f56bff5a4fd7e
Type: Replicate
Volume ID: 36fe8d81-ca0e-4824-a1ce-20a1be2a0537
Status: Started
Snapshot Count: 0
Number of Bricks: 1 x 3 = 3
Transport-type: tcp
Bricks:
Brick1: 10.99.4.161:/var/lib/heketi/mounts/vg_485ff79559cd8729a26277d9639fbf9f/brick_8f0fe0c817aa4d3d895191460ba16934/brick
Brick2: 10.99.3.216:/var/lib/heketi/mounts/vg_2a6899a40ccf4f14452b26f596980770/brick_210177139925936e15a0a6c90ea94e2b/brick
Brick3: 10.99.5.91:/var/lib/heketi/mounts/vg_2bf80889f5716b5fbbe8d578c6785f28/brick_8b703673bba40c80e3ae0e98355185ee/brick
Options Reconfigured:
transport.address-family: inet
performance.readdir-ahead: on
nfs.disable: on
 
root@ip-10-99-3-216:/opt/heketi# heketi-cli volume delete 3cc7ce25f5e7c441b64f56bff5a4fd7e
Volume 3cc7ce25f5e7c441b64f56bff5a4fd7e deleted
```

# Kubernetes Dynamic Provisioner

Now that we have Heketi setup and working we can move to k8s integration. The `glusterfs-client` package needs to be installed on all k8s nodes otherwise the mounting of the GlusterFS volumes will fail (I'm using Kops AMI's which are Debian Jessie based):

```
$ wget -O - http://download.gluster.org/pub/gluster/glusterfs/3.8/LATEST/rsa.pub | sudo apt-key add - && \
echo deb http://download.gluster.org/pub/gluster/glusterfs/3.8/LATEST/Debian/jessie/apt jessie main | sudo tee /etc/apt/sources.list.d/gluster.list && \
apt-get update && sudo apt install -y glusterfs-client
```

Kuberentes has built-in plugin for GlusterFS. We need to create a new glusterfs storage class that will use our Heketi service but first we create a Secret for the admin user password in the following `gluster-secret.yml` file:

```
apiVersion: v1
kind: Secret
metadata:
  name: heketi-secret
  namespace: default
type: "kubernetes.io/glusterfs"
data:
  # echo -n "PASSWORD" | base64
  key: PASSWORD_BASE64_ENCODED
```

and then the StorageClass YAML file `gluster-heketi-external-storage-class.yml` it self:

``` 
kind: StorageClass
apiVersion: storage.k8s.io/v1beta1
metadata:
  name: gluster-heketi-external
provisioner: kubernetes.io/glusterfs
parameters:
  resturl: "http://glustera:8080"
  restuser: "admin"
  secretName: "heketi-secret"
  secretNamespace: "default"
  volumetype: "replicate:3"
  #gidMin: "40000"
  #gidMax: "50000"
```

and create the resources:

```
$ kubectl create -f gluster-secret.yml
secret "heketi-secret" created
$ kubectl create -f gluster-heketi-external-storage-class.yml
storageclass "gluster-heketi-external" created
```

To test it we create a PVC (Persistent Volume Claim) that should dynamically provision a 2GB volume for us in the Gluster storage:

```
$ vi glusterfs-pvc-storageclass.yml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
 name: gluster-dyn-pvc
 annotations:
   volume.beta.kubernetes.io/storage-class: gluster-heketi-external
spec:
 accessModes:
  - ReadWriteMany
 resources:
   requests:
     storage: 2Gi
 
$ kubectl create --save-config -f glusterfs-pvc-storageclass.yml
persistentvolumeclaim "gluster-dyn-pvc" created
```

If we check now:

```
$ kubectl get pv,pvc -n default
NAME                                          CAPACITY   ACCESSMODES   RECLAIMPOLICY   STATUS    CLAIM                                      STORAGECLASS              REASON    AGE
pv/pvc-4b2aeebc-40f5-11e7-a30f-0a40ea97115b   2Gi        RWX           Delete          Bound     default/gluster-dyn-pvc                    gluster-heketi-external             2m
[...]
 
NAME                                   STATUS    VOLUME                                     CAPACITY   ACCESSMODES   STORAGECLASS              AGE
pvc/gluster-dyn-pvc                    Bound     pvc-4b2aeebc-40f5-11e7-a30f-0a40ea97115b   2Gi        RWX           gluster-heketi-external   8m
pvc/mongo-persistent-storage-mongo-0   Bound     pvc-81f37cd6-18f8-11e7-9cea-06d6a42145db   100Gi      RWO           default                   50d
[...]
```

we can see a PV (Persistent Volume) pvc-4b2aeebc-40f5-11e7-a30f-0a40ea97115b of 2GB has been created for us. We can see the new volume on the GlusterFS server too:

```
root@ip-10-99-3-216:~# gluster volume list
vol_4b5d4d20add4fe50a5e415b852442bbc
```

To use the volume we reference the PVC in the YAML file of any Pod/Deployment/StatefulSet like this for example:

```
apiVersion: v1
kind: Pod
metadata:
  name: gluster-pod1
  labels:
    name: gluster-pod1
spec:
  containers:
  - name: gluster-pod1
    image: gcr.io/google_containers/nginx-slim:0.8
    ports:
    - name: web
      containerPort: 80
    securityContext:
      privileged: true
    volumeMounts:
    - name: gluster-vol1
      mountPath: /usr/share/nginx/html
  volumes:
  - name: gluster-vol1
    persistentVolumeClaim:
      claimName: gluster-dyn-pvc
```

I'll just show quickly a test of the storage inside the nginx Pod created from the above YAML:

```
$ kubectl exec -ti gluster-pod1 -- /bin/sh
# cd /usr/share/nginx/html
# echo 'Hello World from GlusterFS!!!' > index.html
# ls
index.html
```

Now if we hit the Pod's URL from another node:

```
root@ip-10-99-6-30:~# curl http://100.86.12.4
Hello World from GlusterFS!!!
```

Long story short, I tested several scenarios of dynamic storage provisioning and sharing it between couple of Pods and then Pods of a same Deployment. Test with Deployment, 2 x containers with the same PVC reference. The Deployment YAML file [nginx-gluster-service-and-deployment.yml]({{ site.baseurl }}/download/nginx-gluster-service-and-deployment.yml):

```
apiVersion: v1
kind: Service
metadata:
  name: nginx-gluster
  namespace: default
  labels:
    name: nginx-gluster
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  selector:
    # This needs to match the selector in the RC/Deployment
    app: nginx-gluster
 
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: nginx-gluster
  namespace: default
  labels:
    app: nginx-gluster
spec:
  revisionHistoryLimit: 0
  replicas: 2
  selector:
    matchLabels:
      app: nginx-gluster
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: nginx-gluster
        tier: frontend
    spec:
      containers:
      - name: nginx-gluster
        image: gcr.io/google_containers/nginx-slim:0.8
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
          name: nginx-gluster
        resources:
          limits:
            cpu: "100m"
            memory: 256Mi
          requests:
            cpu: "10m"
            memory: 64Mi
        readinessProbe:
          successThreshold: 1
          failureThreshold: 2
          periodSeconds: 5
          initialDelaySeconds: 5
          httpGet:
            path: /
            port: 80
            scheme: HTTP
        livenessProbe:
          successThreshold: 1
          failureThreshold: 2
          periodSeconds: 5
          initialDelaySeconds: 5
          timeoutSeconds: 1
          httpGet:
            path: /
            port: 80
            scheme: HTTP
        lifecycle:
          preStop:
            exec:
              command: ["sleep", "5"]
        securityContext:
          privileged: true
        volumeMounts:
        - name: gluster-vol1
          mountPath: /usr/share/nginx/html
      volumes:
      - name: gluster-vol1
        persistentVolumeClaim:
          claimName: gluster-dyn-pvc
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      terminationGracePeriodSeconds: 30
```

Some printouts of the mount points on the k8s nodes and accessing the storage via the Service endpoint for the Deployment are given below:

```
$ kubectl get svc -l name=nginx-gluster -o wide
NAME            CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE       SELECTOR
nginx-gluster   100.65.201.19   <none>        80/TCP    26m       app=nginx-gluster
 
$ kubectl get pods -l app=nginx-gluster -o wide
NAME                             READY     STATUS    RESTARTS   AGE       IP            NODE
nginx-gluster-2959091722-txsdc   1/1       Running   0          37m       100.86.12.8   ip-10-99-6-30.eu-west-1.compute.internal
nginx-gluster-2959091722-zb39s   1/1       Running   0          59m       100.86.12.6   ip-10-99-6-30.eu-west-1.compute.internal
 
root@ip-10-99-6-30:~# cat /proc/mounts | grep -i glust
10.99.3.216:vol_0c330680397affd3f125aa262e714a3b /var/lib/kubelet/pods/a0998b58-4102-11e7-a30f-0a40ea97115b/volumes/kubernetes.io~glusterfs/pvc-26d6c079-40f8-11e7-b0a2-02979b9ae8eb fuse.glusterfs rw,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=131072 0 0
 
root@ip-10-99-8-43:~# cat /proc/mounts | grep -i glust
10.99.3.216:vol_0c330680397affd3f125aa262e714a3b /var/lib/kubelet/pods/a0999030-4102-11e7-a30f-0a40ea97115b/volumes/kubernetes.io~glusterfs/pvc-26d6c079-40f8-11e7-b0a2-02979b9ae8eb fuse.glusterfs rw,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=131072 0 0
 
root@ip-10-99-8-25:~# curl http://100.65.201.19
Hello World from GlusterFS!!!
```

{% include series.html %}
