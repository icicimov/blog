---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kops Kubernetes Cluster upgrades'
categories: 
  - Virtualization
tags: [kubernetes, docker, containers, kops]
date: 2020-6-1-Kops-Kubernetes-Cluster-upgrades
---

Some notes and rules on upgrades to the Kubernetes clusters with Kops I've adopted during more than 3 years of working with Kops and Kubernetes. I always follow the below rules to avoid ending up with a broken cluster. And they probably work since I still have clusters created with version `1.4` running and upgraded to the latest Kubernetes version to this date.

* **Always read Kubernetes RELEASE Notes**: The Kubernetes release notes have important details about new and/or deprecated features that you need to be aware of in order to take advantage of the new and remove the old ones (that WILL break your cluster if not removed from the config). Especially important in case you have done some custom changes to any of the flags for Kubelet, API server or Controller Manager lets say. I've done that many times in the past when I wanted to use some Beta or Alfa feature in the current version instead of waiting for it to become stable later on.

* **Always read Kops RELEASE Notes**: The Kops release notes are equally important, they contain info about the upgrade process and various changes you need to be aware of. Take 1.12 for example [1.12-NOTES.md](https://github.com/kubernetes/kops/blob/master/docs/releases/1.12-NOTES.md) which was a major change to how `etcd` operates in the cluster. Some upgrades will even require to update the current major version to the latest minor version before proceeding to the next major one for example. Or have important notes about possible impact on the CNI plugin your cluster is using or any other system component or add-on. Follow the notes and you should be fine. And read further below for what NOT to do.

* **Never skip Kops/Kubernetes version**: Always upgrade incrementally and never skip a version (no matter what other people say somewhere claiming the opposite)! Don't upgrade from 1.10 to 1.13 lets say or risk a broken cluster! The above mentioned 1.12 version is a good example of what you might miss. You will miss some important change(s) introduced somewhere along the line that Kops needs to apply, your upgrade will fail leaving you with no masters and no cluster at all. Instead upgrade incrementally, go to 1.11 first then 1.12 and finally 1.13. You can get lucky once, but believe me you just got lucky and that's all, don't take that as a regular way to upgrade. The next time you will not be so lucky.

* **Always use matching version of Kops**: Even the smallest change of the Kops minor version can have an impact! If you have created the cluster with 1.16.2 version then stick with it during the updates, i.e. don't use the newer 1.16.3 that was released in the meantime or you might face an unpleasant surprise in form of Kops wanting to roll over your nodes. What happens is that they might have done some changes/fixes in 1.16.3 that impacts the instance user-data which in turn needs you to roll over the cluster. That much of that small, no impact change to the Security Group you wanted to make. Goes without saying that this is a big no-no in case of mixing major versions except if you are upgrading the cluster of course.

* **Cut down custom changes to minimum**: Or not at all if possible. Let the Kops team do the heavy lifting for you and come up with a sane and heavily tested configuration they set by default for the cluster. Otherwise you have to keep an eye on those custom changes and keep making manual updates yourself for the lifetime of the cluster and risk broken upgrades in case you fail to do so.

For me Kops has shown to be a indispensable tool in managing Kubernetes clusters in AWS. Being a "one-man-team" for a long time I would have never done it without Kops and am endlessly grateful for Kops doing the heavy lifting as much as possible instead of me staying on top of all the features across Kubernetes which is basically impossible for a single person. The project documentation has very much improved with time so RTFM, no excuses. And there is also the `#kops-users` Slack channel of course with a supportive and friendly community that is a joy to be a member of.