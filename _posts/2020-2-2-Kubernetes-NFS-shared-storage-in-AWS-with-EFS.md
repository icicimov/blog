---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes NFS shared storage in AWS with EFS'
categories: 
  - Virtualization
tags: [kubernetes, docker, containers, kops]
date: 2020-2-2
---

# AWS efs-provisioner plugin

I'm using the [efs-provisioner](https://github.com/kubernetes-incubator/external-storage/tree/master/aws/efs) driver. There is a CSI storage driver too [aws-efs-csi-driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver) available. To use the driver the K8S nodes need to have `dns-common` package installed for the Debian flavored Linux distros.

## EFS File System

Create a Security Group in the Kubernetes VPC and open TCP port `2049` (NFS) for access from the worker nodes SG. For Kops the SG for the default `nodes` Instance Group is `nodes.<cluster-name>`.

Now login to the EFS service in the EC2 console and create a new File System. Select the above created SG in the `Mount targets` section. There is an encryption option too if needed for the storage.

In the `Client Access` section use the appropriate check boxes to create a Policy that allows client root access to the share. The Policy should look like this in its JSON format:

```json
{
    "Version": "2012-10-17",
    "Id": "efs-policy-wizard-<random-uid>",
    "Statement": [
        {
            "Sid": "efs-statement-<random-uid>",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess"
            ],
            "Resource": "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-xxxxxxxx"
        }
    ]
}
```

Note the File System id `fs-xxxxxxxx` and DNS name `fs-xxxxxxxx.efs.eu-west-1.amazonaws.com` when the provisioning is finished.

## Kubernetes Storage Class

Create the following `efs.yml` file (drop the RBAC part and the `serviceAccount` line if not used) and set the above values and the correct AWS region at the bottom of the file:

```yaml
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: efs-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-efs-provisioner
subjects:
  - kind: ServiceAccount
    name: efs-provisioner
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: efs-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-efs-provisioner
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-efs-provisioner
subjects:
  - kind: ServiceAccount
    name: efs-provisioner
    namespace: kube-system
roleRef:
  kind: Role
  name: leader-locking-efs-provisioner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: efs-provisioner
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: efs-provisioner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: efs-provisioner
  strategy:
    type: Recreate 
  template:
    metadata:
      labels:
        app: efs-provisioner
    spec:
      serviceAccount: efs-provisioner
      containers:
        - name: efs-provisioner
          image: quay.io/external_storage/efs-provisioner:latest
          env:
            - name: FILE_SYSTEM_ID
              valueFrom:
                configMapKeyRef:
                  name: efs-provisioner
                  key: file.system.id
            - name: AWS_REGION
              valueFrom:
                configMapKeyRef:
                  name: efs-provisioner
                  key: aws.region
            - name: DNS_NAME
              valueFrom:
                configMapKeyRef:
                  name: efs-provisioner
                  key: dns.name
                  optional: true
            - name: PROVISIONER_NAME
              valueFrom:
                configMapKeyRef:
                  name: efs-provisioner
                  key: provisioner.name
          volumeMounts:
            - name: pv-volume
              mountPath: /persistentvolumes
      volumes:
        - name: pv-volume
          nfs:
            server: fs-xxxxxxxx.efs.eu-west-1.amazonaws.com
            path: /
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: aws-efs
provisioner: example.com/aws-efs
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: efs-provisioner
data:
  file.system.id: fs-xxxxxxxx 
  aws.region: eu-west-1
  provisioner.name: example.com/aws-efs
  dns.name: ""
```

and apply the manifest:

```bash
$ kubectl apply -n kube-system -f efs.yml
```

We should now see our new `StorageClass`:

```bash
$ kubectl get sc
NAME            PROVISIONER             AGE
aws-efs         example.com/aws-efs     3h35m
[...]
```

and the provisioner Pod(s) running:

```bash
$ kubectl get pods -n kube-system -l app=efs-provisioner
NAME                               READY   STATUS    RESTARTS   AGE
efs-provisioner-759446fcfb-v49pb   1/1     Running   0          77m
```

**NOTE**: The following step is only required in case you want to set `path: /persistentvolumes` instead of `path: /` under `volumes:` above for some reason.

Create the `/persistentvolumes` directory that the `aws-efs` will use by default. I do it by mounting the NFS share on one of the cluster nodes:

```bash
user@host:~$ ssh 10.10.1.139
admin@ip-10-10-1-139:~$ sudo mkdir /mnt/efs
admin@ip-10-10-1-139:~$ sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport fs-xxxxxxxx.efs.eu-west-1.amazonaws.com:/ /mnt/efs
admin@ip-10-10-1-139:~$ sudo mkdir /mnt/efs/persistentvolumes
```

This is the only way I have found to make this option work.

## Usage

Create the following `efs-pvc-and-pod-test.yml` manifest:

```yaml
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: efs
  annotations:
    volume.beta.kubernetes.io/storage-class: "aws-efs"
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
---
kind: Pod
apiVersion: v1
metadata:
  name: test-pod
  labels:
    app: efs-test
spec:
  containers:
  - name: test-pod
    image: gcr.io/google_containers/busybox:1.24
    command:
      - "/bin/sh"
    args:
      - "-c"
      - "touch /mnt/SUCCESS && exit 0 || exit 1"
    volumeMounts:
      - name: efs-pvc
        mountPath: "/mnt"
  restartPolicy: "Never"
  volumes:
    - name: efs-pvc
      persistentVolumeClaim:
        claimName: efs
```

and apply:

```bash
$ kubectl apply -f efs-pvc-and-pod-test.yml 
persistentvolumeclaim/efs created
pod/test-pod created

```

The check for the new PV:

```bash
$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM         STORAGECLASS   REASON   AGE
pvc-eac45e51-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Mi        RWX            Delete           Bound    default/efs   aws-efs                 3m41s

$ kubectl get pvc
NAME   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
efs    Bound    pvc-eac45e51-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Mi        RWX            aws-efs        3m44s
```

and the Pod status:

```bash
$ kubectl get pods -l app=efs-test
NAME       READY   STATUS      RESTARTS   AGE     LABELS
test-pod   0/1     Completed   0          5m14s   app=efs-test
```

To cleanup run:

```bash
$ kubectl delete -f efs.yml
```