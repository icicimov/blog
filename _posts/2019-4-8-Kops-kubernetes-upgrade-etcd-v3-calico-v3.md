---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kops Kubernetes upgrade to etcd-v3 with etcd-manager and calico-v3'
categories: 
  - Kubernetes
tags: ['kubernetes','etcd']
date: 2019-4-8
---

This is to document a procedure I followed during Kubernetes cluster upgrade from 1.10 to latest 1.12 with [kops](https://github.com/kubernetes/kops). I've been using `kops` for all our test and production clusters in AWS and it has proved itself as a toll I can rely on to do the job. I create the private VPC infrastructure with Terraform and then hand over the tasks of creating and managing the Kubernetes cluster to kops.

During this upgrade there is a critical point where we transit from etcd-v2 to etcd-v3 and we hand over the control of etcd to kops's [etcd-manager](https://github.com/kopeio/etcd-manager). It makes it critical for us since most of our clusters use Calico CNI for networking which in its version v2.x depends on etcd-v2 as storage backend. 

## Preparation

Read the documentation linked under the [References](#references) section.

## Upgrade to k8s-1.11

I just want to cruise through this version without any significant changes since my target version is 1.12. Also there's been an issue reported with `etcd-manager` and kops-1.11 where one of the members did not join the cluster, see [kops issue](https://github.com/kubernetes/kops/issues/6736) for details.

Before we begin, make sure to remove any tags not supported in 1.11 from the kops cluster config or the affected pods will get into crash-restart loop. For me that was `enableCustomMetrics` from `kubelet` and `authorizationRbacSuperUser` from `kubeAPIServer`. 

The rest is pretty much straight forward.

```bash
$ /tmp/kops-1.11.1 upgrade cluster --name=<cluster-name>
$ /tmp/kops-1.11.1 upgrade cluster --name=<cluster-name> --yes
$ /tmp/kops-1.11.1 update cluster --name=<cluster-name>
$ /tmp/kops-1.11.1 update cluster --name=<cluster-name> --yes
$ /tmp/kops-1.11.1 rolling-update cluster --name=<cluster-name> --instance-group=master-eu-west-1a --yes
$ /tmp/kops-1.11.1 rolling-update cluster --name=<cluster-name> --instance-group=master-eu-west-1b --yes
$ /tmp/kops-1.11.1 rolling-update cluster --name=<cluster-name> --instance-group=master-eu-west-1c --yes
$ /tmp/kops-1.11.1 rolling-update cluster --name=<cluster-name> --instance-group=nodes
$ /tmp/kops-1.11.1 rolling-update cluster --name=<cluster-name> --instance-group=nodes --yes
```

This went smooth on the first cluster I updated. On the second one I noticed kops was going to set up etcd-manager and pull in etcd-v3 although I did not tell it to do so -- etcd-manager is suppose to be default install starting with kops 1.12 and an opt in option in 1.11. It might had been just me copy-paste a wrong command at some point. Anyway, had to run:

```bash
$ export KOPS_FEATURE_FLAGS=SpecOverrideFlag
$ /tmp/kops-1.11.1 set cluster cluster.spec.etcdClusters[*].provider=Legacy --name=<cluster-name>
$ /tmp/kops-1.11.1 set cluster cluster.spec.etcdClusters[*].version=2.2.1 --name=<cluster-name>
```

before I went on with the upgrade to 1.11.

## Upgrade to k8s-1.12

We need to upgrade using kops 1.12 binary which is in beta atm. We tell the cluster we want to hand over the control of etcd to the `etcd-manager` (this is default in 1.12 anyway) but keep etcd-v2.2.1 so we don't brake Calico. See [etcd3-migration](https://github.com/kubernetes/kops/blob/master/docs/etcd3-migration.md) guide for details about `Gradual updates` in existing clusters.

Before we begin we take etcd backup:

```bash
$ BACKUP_NAME="etcd_backup_$(date +%F).tgz"
$ ETCD_DATA_DIR="/var/etcd/data"
$ ETCD_POD="etcd-server-ip-10-120-3-14.eu-west-1.compute.internal"

$ kubectl exec -t $ETCD_POD -n kube-system -- sh -c "rm -rf /backup && etcdctl backup --data-dir=${ETCD_DATA_DIR} --backup-dir=/backup && tar -czf ${BACKUP_NAME} /backup"
tar: removing leading '/' from member names

$ kubectl cp -n kube-system $ETCD_POD:/${BACKUP_NAME} ./
tar: removing leading '/' from member names

$ ls -l $BACKUP_NAME
-rw-rw-r-- 1 igorc igorc 1260853 Apr  5 15:23 etcd_backup_2019-04-05.tgz
```

Or even better, take EBS snapshots of all manager EBS volumes. Upgrade to 1.12:

```bash
$ /tmp/kops-1.12.0-beta.1 upgrade cluster --name=<cluster-name>
$ /tmp/kops-1.12.0-beta.1 upgrade cluster --name=<cluster-name> --yes
```

Make cluster config changes, keep etcd at v2.2.1:

```bash
$ /tmp/kops-1.12.0-beta.1 set cluster cluster.spec.etcdClusters[*].provider=Manager --name=<cluster-name>
$ /tmp/kops-1.12.0-beta.1 set cluster cluster.spec.etcdClusters[*].version=2.2.1 --name=<cluster-name>
```

Then we update and upgrade:

```bash
$ /tmp/kops-1.12.0-beta.1 update cluster --name=<cluster-name>
$ /tmp/kops-1.12.0-beta.1 update cluster --name=<cluster-name> --yes
$ /tmp/kops-1.12.0-beta.1 rolling-update cluster --name=<cluster-name> --cloudonly --master-interval=1s --node-interval=1s
NAME            STATUS      NEEDUPDATE  READY   MIN MAX
master-eu-west-1a   NeedsUpdate 1       0   1   1
master-eu-west-1b   NeedsUpdate 1       0   1   1
master-eu-west-1c   NeedsUpdate 1       0   1   1
nodes               NeedsUpdate 3       0   3   3

Must specify --yes to rolling-update.

$ /tmp/kops-1.12.0-beta.1 rolling-update cluster --name=<cluster-name> --cloudonly --master-interval=1s --node-interval=1s --yes
```

The upgrade was successful:

```bash
$ kubectl get nodes
NAME                                         STATUS    ROLES     AGE       VERSION
ip-10-120-3-5.eu-west-1.compute.internal     Ready     master    4m        v1.12.7
ip-10-120-3-91.eu-west-1.compute.internal    Ready     node      2m        v1.12.7
ip-10-120-4-81.eu-west-1.compute.internal    Ready     node      21s       v1.12.7
ip-10-120-4-83.eu-west-1.compute.internal    Ready     master    4m        v1.12.7
ip-10-120-5-240.eu-west-1.compute.internal   Ready     node      1m        v1.12.7
ip-10-120-5-90.eu-west-1.compute.internal    Ready     master    3m        v1.12.7
```

And we can see the `etcd-server` and `etcd-events` pods have been replaced by `etcd-manager` ones:

```bash
$ kubectl get pods -n kube-system -l k8s-app=etcd-server
No resources found.

$ kubectl get pods -n kube-system
NAMESPACE       NAME                                                                READY     STATUS    RESTARTS   AGE
kube-system     etcd-manager-events-ip-10-120-3-5.eu-west-1.compute.internal        1/1       Running   0          5m
kube-system     etcd-manager-events-ip-10-120-4-83.eu-west-1.compute.internal       1/1       Running   0          5m
kube-system     etcd-manager-events-ip-10-120-5-90.eu-west-1.compute.internal       1/1       Running   0          4m
kube-system     etcd-manager-main-ip-10-120-3-5.eu-west-1.compute.internal          1/1       Running   0          5m
kube-system     etcd-manager-main-ip-10-120-4-83.eu-west-1.compute.internal         1/1       Running   0          5m
kube-system     etcd-manager-main-ip-10-120-5-90.eu-west-1.compute.internal         1/1       Running   0          4m
```

Also confirmed that the `etcd-manager` activated the etcd hourly backups and they started being uploaded to the kops S3 bucket under /backups/etcd/main and /backups/etcd/events.

Another thing worth mentioning is that in 1.12 Calico gets promoted to CRD:

```bash
$ kubectl get crd | grep calico
bgpconfigurations.crd.projectcalico.org       44m
bgppeers.crd.projectcalico.org                44m
clusterinformations.crd.projectcalico.org     44m
felixconfigurations.crd.projectcalico.org     44m
globalnetworkpolicies.crd.projectcalico.org   44m
globalnetworksets.crd.projectcalico.org       44m
hostendpoints.crd.projectcalico.org           44m
ippools.crd.projectcalico.org                 44m
networkpolicies.crd.projectcalico.org         44m
```

## Upgrade to etcd-v3.2.18 and Calico-v3.4

Set etcd version to 3.2.18:

```bash
$ /tmp/kops-1.12.0-beta.1 set cluster --name=<cluster-name> cluster.spec.etcdClusters[*].version=3.2.18
```

Don't enable TLS (enableEtcdTLS) before upgrading Calico to v3, I've seen issues reported in the kops Slack channel during upgrade when this is the case. We can always do this later if we want to:

```bash
$ kops set cluster --name=<cluster-name> cluster.spec.etcdClusters[*].enableEtcdTLS=true
```

Set major version to v3 for Calico in the cluster config file (this might not be necessary but there was a bug in kops where Calico was not simultaneously updated):

```
spec:
  networking:
    calico:
      crossSubnet: true
      mtu: 8981
      majorVersion: v3
```
I thought this should be possible to set via command line too:

```bash
$ /tmp/kops-1.12.0-beta.1 set cluster --name=<cluster-name> cluster.spec.networking.calico.majorVersion=v3
```

but it failed with the error:

```
unhandled field: "cluster.spec.networking.calico.majorVersion=v3"
```

Then update and check the output:

```bash
$ /tmp/kops-1.12.0-beta.1 update cluster --name=<cluster-name>

Will modify resources:
  LaunchConfiguration/master-eu-west-1a.masters.<cluster-name>
    UserData            
                            ...
                              etcdClusters:
                                events:
                            +     version: 3.2.18
                            -     version: 2.2.1
                                main:
                            +     version: 3.2.18
                            -     version: 2.2.1

  ManagedFile/k8s-uk.encompasshost.internal-addons-bootstrap
    Contents            
                          ...
                          +     manifest: networking.projectcalico.org/k8s-1.7-v3.yaml
                          -     manifest: networking.projectcalico.org/k8s-1.7.yaml
                                name: networking.projectcalico.org
                                selector:
                                  role.kubernetes.io/networking: "1"
                          +     version: 3.4.0-kops.3
                          -     version: 2.6.12-kops.1
```

We will also see messages about Calico CNI plugin being upgraded to v3.4.0. Run the upgrade, as pointed by [etcd3-migration](https://github.com/kubernetes/kops/blob/master/docs/etcd3-migration.md#calico-users) Calico users need to do this as all-in-one instead in rolling manner (it makes sense since at one point etcd will be at v3 which calico v2 does not know how to talk to):

```bash
$ /tmp/kops-1.12.0-beta.1 update cluster --name=<cluster-name> --yes
$ /tmp/kops-1.12.0-beta.1 rolling-update cluster --name=<cluster-name> --cloudonly --master-interval=1s --node-interval=1s --yes
NAME            STATUS      NEEDUPDATE  READY   MIN MAX
master-eu-west-1a   NeedsUpdate 1       0   1   1
master-eu-west-1b   NeedsUpdate 1       0   1   1
master-eu-west-1c   NeedsUpdate 1       0   1   1
nodes               NeedsUpdate 3       0   3   3
W0408 16:01:54.010281   24998 instancegroups.go:160] Not draining cluster nodes as 'cloudonly' flag is set.
I0408 16:01:54.010299   24998 instancegroups.go:301] Stopping instance "i-0951dc991d80ab43c", in group "master-eu-west-1a.masters.<cluster-name>" (this may take a while).
I0408 16:01:54.462062   24998 instancegroups.go:198] waiting for 1s after terminating instance
W0408 16:01:55.462411   24998 instancegroups.go:206] Not validating cluster as cloudonly flag is set.
W0408 16:01:55.462477   24998 instancegroups.go:160] Not draining cluster nodes as 'cloudonly' flag is set.
I0408 16:01:55.462504   24998 instancegroups.go:301] Stopping instance "i-04c446f107c88e14f", in group "master-eu-west-1b.masters.<cluster-name>" (this may take a while).
I0408 16:01:55.898525   24998 instancegroups.go:198] waiting for 1s after terminating instance
W0408 16:01:56.898790   24998 instancegroups.go:206] Not validating cluster as cloudonly flag is set.
W0408 16:01:56.898877   24998 instancegroups.go:160] Not draining cluster nodes as 'cloudonly' flag is set.
I0408 16:01:56.898903   24998 instancegroups.go:301] Stopping instance "i-0a0c45980ea721380", in group "master-eu-west-1c.masters.<cluster-name>" (this may take a while).
I0408 16:01:57.309771   24998 instancegroups.go:198] waiting for 1s after terminating instance
W0408 16:01:58.310085   24998 instancegroups.go:206] Not validating cluster as cloudonly flag is set.
W0408 16:01:58.310713   24998 instancegroups.go:160] Not draining cluster nodes as 'cloudonly' flag is set.
I0408 16:01:58.310768   24998 instancegroups.go:301] Stopping instance "i-02a7800413a89c339", in group "nodes.<cluster-name>" (this may take a while).
I0408 16:01:58.751713   24998 instancegroups.go:198] waiting for 1s after terminating instance
W0408 16:01:59.752091   24998 instancegroups.go:206] Not validating cluster as cloudonly flag is set.
W0408 16:01:59.752155   24998 instancegroups.go:160] Not draining cluster nodes as 'cloudonly' flag is set.
I0408 16:01:59.752182   24998 instancegroups.go:301] Stopping instance "i-08f03edd19e4f9dcf", in group "nodes.<cluster-name>" (this may take a while).
I0408 16:02:00.175247   24998 instancegroups.go:198] waiting for 1s after terminating instance
W0408 16:02:01.175622   24998 instancegroups.go:206] Not validating cluster as cloudonly flag is set.
W0408 16:02:01.175673   24998 instancegroups.go:160] Not draining cluster nodes as 'cloudonly' flag is set.
I0408 16:02:01.175697   24998 instancegroups.go:301] Stopping instance "i-0f4135cb0f5fed13f", in group "nodes.<cluster-name>" (this may take a while).
I0408 16:02:01.632555   24998 instancegroups.go:198] waiting for 1s after terminating instance
W0408 16:02:02.632836   24998 instancegroups.go:206] Not validating cluster as cloudonly flag is set.
I0408 16:02:02.632923   24998 rollingupdate.go:184] Rolling update completed for cluster "<cluster-name>"!
```

Now, at first this will fail since the API DNS record `api.internal.<cluster-name>` does not get updated and holds on to the IPs of the old masters that have been recycled, maybe related to [kops issue](https://github.com/kubernetes/kops/issues/6727).

We go to the DNS zone and manually set the A record value to the current master nodes IPs. After that change we can see in the kubelet logs the cluster begins to form, calico pods get created and all springs back to life. 

```bash
$ kubectl get nodes
NAME                                         STATUS    ROLES     AGE       VERSION
ip-10-120-3-121.eu-west-1.compute.internal   Ready     master    25m       v1.12.7
ip-10-120-3-149.eu-west-1.compute.internal   Ready     node      23m       v1.12.7
ip-10-120-4-141.eu-west-1.compute.internal   Ready     node      23m       v1.12.7
ip-10-120-4-18.eu-west-1.compute.internal    Ready     master    25m       v1.12.7
ip-10-120-5-109.eu-west-1.compute.internal   Ready     node      23m       v1.12.7
ip-10-120-5-85.eu-west-1.compute.internal    Ready     master    25m       v1.12.7
```

Lets check the etcd status:

```bash
$ kubectl get pods -n kube-system -l k8s-app=etcd-manager-main
NAME                                                             READY     STATUS    RESTARTS   AGE
etcd-manager-main-ip-10-120-3-121.eu-west-1.compute.internal     1/1       Running   0          3m
etcd-manager-main-ip-10-120-4-18.eu-west-1.compute.internal      1/1       Running   0          3m
etcd-manager-events-ip-10-120-5-85.eu-west-1.compute.internal    1/1       Running   0          4m

$ kubectl get pods -n kube-system -l k8s-app=etcd-manager-events
NAME                                                             READY     STATUS    RESTARTS   AGE
etcd-manager-events-ip-10-120-3-121.eu-west-1.compute.internal   1/1       Running   0          4m
etcd-manager-events-ip-10-120-4-18.eu-west-1.compute.internal    1/1       Running   0          3m
etcd-manager-events-ip-10-120-5-85.eu-west-1.compute.internal    1/1       Running   0          4m
```

and Calico too:

```bash
$ kubectl get pods -n kube-system -l k8s-app=calico-node
NAME                READY     STATUS    RESTARTS   AGE
calico-node-5774b   1/1       Running   0          23m
calico-node-88qfj   1/1       Running   0          23m
calico-node-d6576   1/1       Running   0          23m
calico-node-dnjk5   1/1       Running   0          22m
calico-node-gnnnm   1/1       Running   0          22m
calico-node-tb6lz   1/1       Running   0          21m

$ kubectl get pods calico-node-5774b -n kube-system -o yaml | grep image | grep node
    image: quay.io/calico/node:v3.4.0
```

## Final thoughts

My experience upgrading Kubernetes 1.10 to 1.12 with kops and etcd-manager varied from one cluster to another. While in one occasion I faced (almost) no problems at all in another the etcd broke and would not establish raft membership. For example during the final upgrade of etcd-v2.2.1 to etcd-v3.2.18 I found that 2 out of 3 masters had mounted a wrong EBS volume for the `etcd-manager-main` pod. They had mounted a `master-eu-west-1a.etcd-main.<cluster-name>` volume (assume from the old v2.2.1 setup) instead of `a.etcd-main.<cluster-name>` one which resulted in members with mixed etcd versions. Interestingly the `etcd-manager-events` cluster showed no issues at all, all was correctly mounted and the cluster was healthy.

## References

* <https://github.com/kubernetes/kops/blob/master/docs/releases/1.11-NOTES.md>
* <https://github.com/kubernetes/kops/blob/master/docs/releases/1.12-NOTES.md>
* <https://github.com/kubernetes/kops/blob/master/docs/etcd/manager.md>
* <https://github.com/kubernetes/kops/blob/master/docs/etcd3-migration.md>
* <https://github.com/kubernetes/kops/blob/master/docs/calico-v3.md#upgrading-an-existing-cluster>