---
type: posts
header:
  teaser: 'docker-gitlab-k8s.png'
title: 'GitLab CI/CD Pipelines for Kubernetes clusters'
categories: 
  - DevOps
tags: ['gitlab', 'kubernetes', 'docker', 'CI/CD', 'aws']
date: 2018-09-02
---

[GitLab](https://docs.gitlab.com/ce/ci/) is a versatile open source (CE edition) tool that provides Git stile project repository, CI/CD pipelines and private [Container Image Registry](https://about.gitlab.com/2016/05/23/gitlab-container-registry/) for the projects. It has built-in integration with Kubernetes and many other useful features like LDAP integration for external authentication, something we use extensively when ever possible. I've been using GitLab for the past year and a half and been really happy with its performance. In fact it's been so good that we decided to move all our GitHub projects to our self hosted GitLab cluster.

In our organization I have GitLab deployed in a separate Kubernetes cluster from where we have centralized management of all other Test and Production clusters. It's been deployed via customized GitLab Omnibus Helm chart. All Kubernetes clusters are created using [kops](https://github.com/kubernetes/kops) in pre-created all private (networking and DNS) AWS VPCs created via [Terraform](https://www.terraform.io/).

The following directory structure is common to all our GitLab projects: 

```
.
├── .generated
├── .git
├── .gitignore
├── .gitlab-ci.yml
├── LICENSE
├── Makefile
├── README.md
├── src
│   ├── ca-certificates.crt
│   ├── Dockerfile
│   ├── index.html
│   ├── server.go
│   └── server_test.go
└── templates
    ├── autoscaler.yml
    ├── deployment.yml
    ├── ingress.yml
    ├── .placeholder
    ├── sa.yml
    ├── sm.yml
    └── svc.yml
```

This is an example of small Golang app I've put together for purpose of Kubernetes cluster and CI/CD Pipeline testing -- provides health and readiness checks, graceful shutdown and Prometheus metrics endpoint. The code is available in my [GitHub repository](https://github.com/icicimov/go-app).

The source code including the `Dockerfile` for building the container image goes under the `src/` directory and the Kubernetes templates under `templates/` directory. In this way we can tell what kind of file changes have triggered the CI/CD Pipeline upon commit/push to the repository and take appropriate action. When there is a minor change to some of the auxiliary files like README the commit message contains `[skip ci]` in it's description thus the change does not trigger the Pipeline unnecessary.

The Pipeline is setup in the `.gitlab-ci.yml` file. For this project it looks like this:

```
variables:
  GIT_SSL_NO_VERIFY: "true"
  DOCKER_DRIVER: overlay2
  DOCKER_HOST: tcp://localhost:2375
  IMAGE_NAME: "$CI_REGISTRY/encompass/go-app"
  BASE_IMAGE_NAME: "${CI_REGISTRY_IMAGE}:latest"
  IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_REF_NAME
  DOCKER_IMAGE: "operations/images/encompass-dind:18.03.0-ce"
  KUBECTL_IMAGE: "operations/images/kubectl_deployer:latest"
  KUBECONFIG: /etc/deploy/config

image: $CI_REGISTRY/$DOCKER_IMAGE
services:
  - docker:stable-dind

stages:
  - test
  - build
  - scan
  - deploy

test:
  stage: test
  image: golang:alpine
  script:
    - docker version
    - cd ./src
    - go test
  only:
    refs:
      - master
    changes:
      - src/*.go

build:
  stage: build
  script:
    - docker version
    - >
        echo BASE_IMAGE_NAME $BASE_IMAGE_NAME
        docker login -u gitlab-ci-token -p $CI_JOB_TOKEN $CI_REGISTRY
        docker pull $BASE_IMAGE_NAME
        docker build --cache-from $BASE_IMAGE_NAME --pull -t "${CI_REGISTRY_IMAGE}:${CI_COMMIT_REF_NAME}_${CI_COMMIT_SHA}" -t $BASE_IMAGE_NAME ./src/
        docker push "${CI_REGISTRY_IMAGE}:${CI_COMMIT_REF_NAME}_${CI_COMMIT_SHA}"
        docker push $BASE_IMAGE_NAME
  only:
    refs:
      - master
    changes:
      - src/*

.container_scanning: &container_scanning
  allow_failure: true
  stage: scan
  script:
    - docker run -d --name db arminc/clair-db:latest
    - docker run -p 6060:6060 --link db:postgres -d --name clair --restart on-failure arminc/clair-local-scan:v2.0.1
    - apk add -U wget ca-certificates
    - docker login -u gitlab-ci-token -p $CI_JOB_TOKEN $CI_REGISTRY
    - docker pull $BASE_IMAGE_NAME 
    - wget https://github.com/arminc/clair-scanner/releases/download/v8/clair-scanner_linux_amd64
    - mv clair-scanner_linux_amd64 clair-scanner
    - chmod +x clair-scanner
    - touch clair-whitelist.yml
    - retries=0
    - echo "Waiting for clair daemon to start"
    - while( ! wget -T 10 -q -O /dev/null http://localhost:6060/v1/namespaces ) ; do sleep 1 ; echo -n "." ; if [ $retries -eq 10 ] ; then echo " Timeout, aborting." ; exit 1 ; fi ; retries=$(($retries+1)) ; done
    - ./clair-scanner -c http://localhost:6060 --ip $(hostname -i) -r gl-container-scanning-report.json -l clair.log -w clair-whitelist.yml $BASE_IMAGE_NAME || true
  artifacts:
    paths: [gl-container-scanning-report.json]

container-scan:
  stage: scan
  <<: *container_scanning
  only:
    - master

# KUBE_CONFIG is project var containing base64 encoded kubeconfig file
# with configuration of the K8S clusters we want to deploy to.
.k8s-deploy: &k8s-deploy
  image: $CI_REGISTRY/$KUBECTL_IMAGE
  services:
    - docker:dind
  before_script:
    - mkdir -p /etc/deploy
    - echo ${KUBE_CONFIG} | base64 -d > ${KUBECONFIG}
  script:
    - kubectl config use-context $KUBECONTEXT
    - cp templates/*.yml ./.generated/
    - >
      if git diff HEAD~ --name-only|grep src; then
        sed -i "s/<VERSION>/${CI_COMMIT_REF_NAME}_${CI_COMMIT_SHA}/" ./.generated/deployment.yml
      else
        sed -i "s/<VERSION>/latest/" ./.generated/deployment.yml
      fi;
    - >
      if git diff HEAD~ --name-only|grep templates; then
        sed -i "s/<HASH>/${CI_COMMIT_SHA}/" ./.generated/deployment.yml
      fi;
    - sed -i "s/<APP_FQDN>/${APP_FQDN}/" ./.generated/ingress.yml
    - cat ./.generated/deployment.yml
    - cat ./.generated/ingress.yml
    - kubectl apply -f ./.generated/sm.yml
    - rm -f ./.generated/sm.yml
    - kubectl apply -f ./.generated -n ${KUBE_NAMESPACE}

# KUBECONTEXT is the context in the kubeconfig file for the 
# cluster we are deploying to. The context references a user
# with enough permissions to perform a deployment.
k8s-deploy-test:
  stage: deploy
  variables:
    KUBECONTEXT: "deployer.test.domain.internal"
    APP_FQDN: "go-app.test.domain.com"
  <<: *k8s-deploy
  environment:
    name: test 
    url: https://go-app.test.domain.com
  only:
    - master

k8s-deploy-prod:
  stage: deploy
  variables:
    KUBECONTEXT: "deployer.prod.domain.internal"
    APP_FQDN: "go-app.prod.domain.com"
  <<: *k8s-deploy
  environment:
    name: prod
    url: https://go-app.prod.domain.com
  when: manual
  only:
    - master
```

The first thing to take a note of is the `DOCKER_IMAGE` variable. Our Pipelines use DinD, Docker-in-Docker, meaning for each stage there is a new Docker container launched in Kubernetes inside which the job gets executed. I have created our own DinD image `encompass-dind:18.03.0-ce` with Git and some other tools that were missing (not sure if this is still the case) from the official stable Docker DinD image and that's what our shared [GitLab Runner](https://docs.gitlab.com/runner/) uses to launch containers from. Another custom image we use is `kubectl_deployer` set in the KUBECTL_IMAGE variable which is used in the deployment stage and has the `kubectl` tool installed.

Then we go through the stages of the Pipeline in order they are defined. Each stage executes only when changes are applied to the `master` branch only. The first is the `test` one that executes only when the Go source code files change. Then comes the `build` stage that build the binary from the source and creates a new Docker images, one tagged as `latest` and one tagged with the commit hash. Then we scan the newly created docker image for vulnerabilities using the Clair scanner provided by this [GitHub project](https://github.com/arminc/clair-local-scan).

The final stage is where we deploy to our Kubernetes clusters. The common tasks are specified via a common template that each of the deployment stages references. As described in the comments above, the KUBE_CONFIG is project var containing `base64` encoded `kubeconfig` file with configuration of the K8S clusters we want to deploy to. Another project variable is KUBE_NAMESPACE where we specify which Kubernetes namespace we want to deploy the app into. The `k8s-deploy` template has the logic where we substitute some strings like `<HASH>` and `<VERSION>` in the deployment manifest:

```
  template:
    metadata:
      labels:
        ...
      annotations:
        deployHash: <HASH>
    spec:
      ...
      containers:
      - name: go-app
        image: registry.domain.com/encompass/go-app:<VERSION>
        imagePullPolicy: Always
...
```

depending on was there a new image created or not.

Each of the deployment stages references this template but substitutes some generic variables with their own specific ones for the cluster. This is where we set the KUBECONTEXT variable to match the cluster context in the `kubeconfig` file and also set the `<APP_FQDN>` in the Ingress manifest to the appropriate domain name:

```
spec:
  rules:
  - host: <APP_FQDN> 
    http:
      paths:
      - backend:
          serviceName: go-app-svc
          servicePort: 80
        path: /
```

The deployment to the Test cluster is executed automatically and if successful the Pipeline pauses and waits for an operator to manually deploy to Production.