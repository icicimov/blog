---
type: posts
header:
  teaser: 'docker-logo-2.png'
title: 'Building Multi Architecture Golang Docker Images with GitLab CI/CD'
categories: 
  - Docker
tags: ['docker','golang','gitlab','CI/CD']
date: 2019-7-23
---

The motivation is to provide Docker images for use with the [AWS EC2 A1 Instances](https://aws.amazon.com/about-aws/whats-new/2018/11/introducing-amazon-ec2-a1-instances/) that deliver significant cost savings and are ideally suited for scale-out and Arm-based workloads that are supported by the extensive Arm ecosystem. A1 instances are the first EC2 instances powered by AWS Graviton Processors that feature 64-bit Arm Neoverse cores and custom silicon designed by AWS.

The build stage of the GitLab DinD (Docker-in-Docker) pipeline is based on [Makefile](https://www.gnu.org/s/make/manual/make.html) and [Docker Manifest](https://docs.docker.com/engine/reference/commandline/manifest/) feature to transparently provide multi-arch info to the Docker client. It uses `docker manifest` command which is experimental and needs to be enabled by editing the `~/.docker/config.json` file and setting `experimental` to `enabled` for the user running the Docker client. The same parameter but with value `true` needs to be enabled for the Docker daemon too in the `/etc/docker/daemon.json` file.

At the end of the GitLab pipeline we end up with multiple images in our private Registry as shown below:

![multiarch-docker-images-gitlab](/blog/images/multiarch-docker-images-gitlab.png)

By providing Docker Manifest to the registry we make it possible to always reference our image as `$DOCKER_REGISTRY/projects/go-proxy-multiarch:[f5b1c7f | latest]` for example no matter the architecture we are running on and the docker client will pull down the correct image for us.

For more info see the [README](https://github.com/icicimov/go-proxy-docker-multiarch/blob/master/README.md) file in the provided GitHub repository.