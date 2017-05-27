---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes shared storage with S3 backend'
categories: 
  - Virtualization
tags: [kubernetes, docker, containers]
date: 2017-4-15
series: "Kubernetes Cluster in AWS"
excerpt: "There are many options available in Kubernetes when it comes to shared storage. I'm using a S3 bucket as backend for the shared storage in a k8s cluster in AWS."
---

The storage is definitely the most complex and most important part of the setup, once solved 80% of the job is done IMHO. I have explored couple of possibilities for shared storage in the Kubernetes cluster.

I used an existing S3 bucket `MY_S3_BUCKET` that already has content inside. An IAM user has been created with full access to the S3 bucket.

## Create s3fs image

The first step is creating our s3fs Docker image so we start with its Dockerfile:

```
########################################################
# The FUSE driver needs elevated privileges, run Docker with --privileged=true 
# or with minimum elevation as shown below:
# $ sudo docker run -d --rm --name s3fs --security-opt apparmor:unconfined \
#  --cap-add mknod --cap-add sys_admin --device=/dev/fuse \
#  -e S3_BUCKET=MY_S3_BUCKET -e S3_REGION=ap-southeast-2 \
#  -e MNT_POINT=/data git.encompasshost.com:5001/encompass/images/s3fs:latest
########################################################
 
FROM ubuntu:14.04
 
MAINTAINER Igor Cicimov <igorc@encompasscorporation.com>
 
ENV DUMB_INIT_VER 1.2.0
ENV S3_BUCKET ''
ENV MNT_POINT /data
ENV S3_REGION ''
ENV AWS_KEY ''
ENV AWS_SECRET_KEY ''
 
RUN DEBIAN_FRONTEND=noninteractive apt-get -y update --fix-missing && \
    apt-get install -y automake autotools-dev g++ git libcurl4-gnutls-dev wget \
                       libfuse-dev libssl-dev libxml2-dev make pkg-config && \
    git clone https://github.com/s3fs-fuse/s3fs-fuse.git /tmp/s3fs-fuse && \
    cd /tmp/s3fs-fuse && ./autogen.sh && ./configure && make && make install && \
    ldconfig && /usr/local/bin/s3fs --version && \
    wget -O /tmp/dumb-init_${DUMB_INIT_VER}_amd64.deb https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VER}/dumb-init_${DUMB_INIT_VER}_amd64.deb && \
    dpkg -i /tmp/dumb-init_*.deb
 
RUN echo "${AWS_KEY}:${AWS_SECRET_KEY}" > /etc/passwd-s3fs && \
    cmod 0400 /etc/passwd-s3fs
 
RUN mkdir -p "$MNT_POINT"
 
RUN DEBIAN_FRONTEND=noninteractive apt-get purge -y wget automake autotools-dev g++ git make && \
    apt-get -y autoremove --purge && apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
 
# Runs "/usr/bin/dumb-init -- CMD_COMMAND_HERE"
#ENTRYPOINT ["/usr/bin/dumb-init", "--"]
 
CMD exec /usr/local/bin/s3fs $S3_BUCKET $MNT_POINT -f -o endpoint=${S3_REGION},allow_other,use_cache=/tmp,max_stat_cache_size=1000,stat_cache_expire=900,retries=5,connect_timeout=10
```

We build and push the image to our private GitLab repository:

```
user@server:~$ sudo docker build --rm -t git.encompasshost.com:5001/encompass/images/s3fs:latest .
user@server:~$ sudo docker push git.encompasshost.com:5001/encompass/images/s3fs:latest
```

### Create Kubernetes Deployment

Create YAML file `s3fs-pod.yml` for the S3 Pod that will launch from our s3fs image we created above:

```
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: s3fs
  selfLink: /apis/extensions/v1beta1/namespaces/deployments/s3fs
  labels:
    app: s3fs
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: s3fs
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      creationTimestamp: null
      labels:
        app: s3fs
        tier: storage
    spec:
      containers:
      - name: s3fs
        image: git.encompasshost.com:5001/encompass/images/s3fs:latest
        imagePullPolicy: Always
        securityContext:
          privileged: true
          # capabilities:
          #   add:
          #     - SYS_ADMIN
          #     - MKNOD
        resources:
          limits:
            cpu: 300m
            memory: 256Mi
          requests:
            cpu: 100m
            memory: 128Mi
        env:
        - name: DUMB_INIT_VER
          value: 1.2.0
        - name: S3_BUCKET
          value: MY_S3_BUCKET
        - name: S3_REGION
          value: ap-southeast-2
        - name: MNT_POINT
          value: /data
        - name: AWS_KEY
            valueFrom:
              secretKeyRef:
                name: s3fs-secret
                key: aws-key
        - name: AWS_SECRET_KEY
            valueFrom:
              secretKeyRef:
                name: s3fs-secret
                key: aws-secret-key
        volumeMounts:
        - name: devfuse
          mountPath: /dev/fuse
      dnsPolicy: ClusterFirst
      imagePullSecrets:
      - name: encompass-gitlab-registry
      restartPolicy: Always
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - name: devfuse
        hostPath:
          path: /dev/fuse
```

The credentials for our private GitLab repository are placed in a Secret `encompass-gitlab-registry`. Next is the Secret for the AWS API credentials of the user that has full access to our S3 bucket:

```
apiVersion: v1
kind: Secret
metadata:
  name: s3fs-secret
  namespace: default
type: Opaque
data:
  # base64 encoded keys
  # echo -n "AWS_KEY|AWS_SECRET_KEY" | base64
  aws-key: AWS_KEY_BASE64
  aws-secret-key: AWS_SECRET_KEY_BASE64
```

Create the Pod and check the status:

```
igorc@z30:~$ kubectl create -f s3fs-pod.yml
deployment "s3fs" created
 
igorc@z30:~$ kubectl get pods -l app=s3fs -n default -o wide
NAME                   READY     STATUS    RESTARTS   AGE       IP             NODE
s3fs-793318855-5m0rn   1/1       Running   0          7s        100.76.88.70   ip-10-99-7-170.eu-west-1.compute.internal
```

Now if we access the Pod and check the mount point `/data` inside:

```
igorc@z30:~$ kubectl exec -it s3fs-793318855-5m0rn -- /bin/bash
 
root@s3fs-793318855-5m0rn:/# cat /proc/mounts | grep s3fs
s3fs /data fuse.s3fs rw,nosuid,nodev,relatime,user_id=0,group_id=0,allow_other 0 0
  
root@s3fs-793318855-5m0rn:/# ls -latr /data/
total 6
drwxrwxrwx 1 root root    0 Jan  1  1970 .
drwxr-xr-x 1  106  112    0 Aug 24  2014 documents
drwx------ 1  106  112    0 Aug 25  2014 pdf
drwxr-xr-x 1  106  112    0 Oct  2  2014 bin
drwxr-xr-x 1 root root 4096 May 12 02:07 ..
 
root@s3fs-793318855-5m0rn:/# ls -latr /data/pdf/
total 2662
drwxrwxrwx 1 root root      0 Jan  1  1970 ..
drwx------ 1  106  112      0 Aug 25  2014 .
-rw-r----- 1 root root     69 May 11 06:51 att2326657820473197074.tmp
-rw-r----- 1 root root  24239 May 11 06:51 att2142735961680455285.tmp
-rw-r----- 1 root root   6312 May 11 06:51 att210752314411941643.tmp
[...]
 
root@s3fs-793318855-5m0rn:/# ls -latr /data/documents/
total 200
drwxrwxrwx 1 root root 0 Jan  1  1970 ..
drwxr-xr-x 1  106  112 0 May 19  2014 2014-05-19
drwxr-xr-x 1  106  112 0 May 20  2014 2014-05-20
drwxr-xr-x 1  106  112 0 May 21  2014 2014-05-21
drwxr-xr-x 1  106  112 0 May 22  2014 2014-05-22
[...]
drwxr-xr-x 1  106  112 0 Jul 15  2016 2016-07-15
drwxr-xr-x 1  106  112 0 Jul 18  2016 2016-07-18
drwxr-xr-x 1  106  112 0 Jul 19  2016 2016-07-19
drwxr-xr-x 1  106  112 0 Jul 25  2016 2016-07-25
```

we can see the content of the S3 bucket.

## Using the S3 bucket as shared volume

We can see the share working. We can use this container as a sidecar in the Pods for services that need shared storage. Another approach is to make the volume share available on the k8s nodes them self, and thus any Pod running on them, via the s3fs pods.

Docker engine 1.10 added a new feature which allows containers to share the host mount namespace. This feature makes it possible to mount a s3fs container file system to a host file system through a shared mount, providing a persistent network storage with S3 backend. Shared mount on the k8s nodes:

```
root@ip-10-99-7-170:~# mkdir /mnt/data-s3fs
root@ip-10-99-7-170:~# mount --bind /mnt/data-s3fs /mnt/data-s3fs
root@ip-10-99-7-170:~# mount --make-shared /mnt/data-s3fs
root@ip-10-99-7-170:~# findmnt -o TARGET,PROPAGATION /mnt/data-s3fs
TARGET         PROPAGATION
/mnt/data-s3fs shared
```

Now we need to make a slight change to our Deployment so we mount the host shared directory into `/data` on the container:

```
[...]
        volumeMounts:
        - name: devfuse
          mountPath: /dev/fuse
        - name: mntdatas3fs
          mountPath: /data:shared
      volumes:
      - name: devfuse
        hostPath:
          path: /dev/fuse
      - name: mntdatas3fs
        hostPath:
          path: /mnt/data-s3fs
[...]
```

and re-apply the YAML file. The key part is `mountPath: /data:shared` which enables the volume to be mounted as shared inside the pod. When the container starts it will mount the S3 bucket onto `/data` and consequently the data will be available under `/mnt/data-s3fs` on the host and thus to any other container/pod running on it (and has `/mnt/data-s3fs` mounted too).

To test lets login to the s3fs pod and create new directory in the share:

```
root@s3fs-793318855-5m0rn:/# ls -l /data                                                                                                                                                                           
total 2
drwxr-xr-x 1 106 112 0 Oct  2  2014 bin
drwxr-xr-x 1 106 112 0 Aug 24  2014 documents
drwx------ 1 106 112 0 Aug 25  2014 pdf
root@s3fs-793318855-5m0rn:/# mkdir /data/test
root@s3fs-793318855-5m0rn:/# ls -ltr /data     
total 2
drwxr-xr-x 1  106  112 0 Oct  2  2014 bin
drwxr-xr-x 1  106  112 0 Aug 24  2014 documents
drwx------ 1  106  112 0 Aug 25  2014 pdf
drwxr-xr-x 1 root root 0 Apr 15 12:37 test
```

and then lets check the share on the k8s node this pod is running on:

```
root@ip-10-99-7-170:~# ls -ltr /mnt/data-s3fs/
total 2
drwxr-xr-x 1 sshd  112 0 Aug 24  2014 documents
drwx------ 1 sshd  112 0 Aug 25  2014 pdf
drwxr-xr-x 1 sshd  112 0 Oct  2  2014 bin
drwxr-xr-x 1 root root 0 Apr 15 12:37 test
```

and we can see the new directory here too.

We can convert the Deployment into DaemonSet and have this running on every node in our cluster and automatically mounting the S3 bucket providing cluster-wise shared storage for our Pods and Services.

{% include series.html %}