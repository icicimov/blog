---
type: posts
header:
  teaser: 'docker-gitlab-k8s.png'
title: 'GitLab CI/CD Multi-project Pipelines for Terraform and AWS'
categories: 
  - DevOps
tags: ['gitlab', 'terraform', CI/CD', 'aws']
date: 2018-12-11
---

I use Terraform to provision our AWS infrastructure. Each production and staging environment gets provisioned in its own VPC and each service is clustered or deployed in highly available manner. My main Terraform code is inside its own GitLab repository in form of modules which are used by all other Terraform projects. Lets call this project `ProjectA`. Then I have a `ProjectB` that I use for end-to-end testing of the main repository, meaning every time I make a change of the `ProjectA`'s modules in the `master` branch I want to trigger the `ProjectB`'s pipeline that will launch a complete VPC so we can test all our services and make sure the changes are sane.

## Target project CI/CD setup

The `ProjectB`, the target project, will have the following pipeline stages:

```yaml
stages:
  - modules 
  - validate
  - plan
  - apply
  - destroy
```

and each stage will include the following `before_script` and job template:

```yaml
before_script:
  - terraform --version
  - mkdir -p ~/.aws
  - echo $AWS_CREDS | base64 -d > ~/.aws/credentials
  - rm -rf .terraform
  - terraform init

.job_template: &job_template
  only:
    refs:
      - master
      - pipelines
      - triggers
      - web
    variables:
      - $CI_PIPELINE_SOURCE == "pipeline"
  except:
    variables:
      - $CI_COMMIT_MESSAGE =~ /skip-e2e-test/
```

In short, first in the `before_script` we set the needed AWS credentials via `base64` encoded project variable `AWS_CREDS`. This is simply created from a file containing a dedicated user's credentials:

```
[default]
aws_access_key_id = xxxxx 
aws_secret_access_key = yyyyy
```

then we obtain the value as:

```bash
$ cat file | base64
```

The AWS IAM credentials have appropriate permissions for Terraform to do it's job and access the S3 backend to store its state file (that is also configured with DynamoDB table for locking thus preventing multiple users making changes to the project in the same time). 

Then we set the conditions we want this pipeline to get started under which are when we push to `master`, via a web hook or manually via the web UI. I have also set a option for trigger via a `CI_PIPELINE_SOURCE` variable that another project can pass in. There is also a `CI_COMMIT_MESSAGE` variable in which I set a condition under which I don't want the pipeline to get triggered which is in case of commit message containing the `skip-e2e-test` string.

As I mentioned before, all my code for the AWS infrastructure is organized in modules in `ProjectA`. They are then referenced in `ProjectB` like this for example:

```
module "vpn" {
    source = "git::https://git.example.com/<group>/ProjectA//modules/vpn"
    ...
}
```

When the `terraform init` gets executed it will pull the `modules` directory from `ProjectA` and compile the modules under local `.terraform` directory. Since I want this `modules` directory carried over between stages (so I don't clone it over and over again) I set a `cache` for it in the pipeline:

```yaml
cache: 
  paths:
    - modules
```

That is more or less the gist of it, the full `.gitlab-ci.yml` file looks like this:

```yaml
variables:
  DOCKER_DRIVER: overlay2
  DOCKER_HOST: tcp://localhost:2375

image:
  name: hashicorp/terraform:0.11.13
  entrypoint:
    - '/bin/sh -c'

stages:
  - modules 
  - validate
  - plan
  - apply
  - destroy

cache: 
  paths:
    - modules

before_script:
  - terraform --version
  - mkdir -p ~/.aws
  - echo $AWS_CREDS | base64 -d > ~/.aws/credentials
  - rm -rf .terraform
  - TF_LOG=trace terraform init

.job_template: &job_template
  only:
    refs:
      - master
      - pipelines
      - triggers
      - web
    variables:
      - $CI_PIPELINE_SOURCE == "pipeline"
  except:
    variables:
      - $CI_COMMIT_MESSAGE =~ /skip-e2e-test/

init:
  stage: modules 
  before_script:
    - echo -e "machine git.example.com\nlogin gitlab-ci-token\npassword ${CI_JOB_TOKEN}" > ~/.netrc
  script:
    - git init pull
    - cd pull
    - git remote add origin https://git.example.com/<group>/ProjectA.git
    - git config core.sparsecheckout true
    - echo "modules/*" > .git/info/sparse-checkout
    - git pull --depth=1 origin master
    - cp -R modules ../
  <<: *job_template

validate:
  stage: validate
  script:
    - terraform validate -var-file variables.tfvars
  dependencies:
    - init 

plan:
  stage: plan
  <<: *job_template
  script:
    - terraform plan -var-file variables.tfvars -out "vpc.tfplan"
  dependencies:
    - validate
  artifacts:
    paths:
      - vpc.tfplan

apply:
  stage: apply
  image: igoratencompass/terraform-awscli:latest
  <<: *job_template
  script:
    - terraform apply -auto-approve -input=false "vpc.tfplan"
  dependencies:
    - plan
  when: manual

destroy:
  stage: destroy
  <<: *job_template
  script:
    - terraform destroy -force -auto-approve -var-file variables.tfvars
  dependencies:
    - apply
  when: manual
```

Now some explanation about the stage I called `modules`. Usually `terraform init` itself would fetch the modules from the source repository one-by-one but in my case that was failing with the error:

```
$ terraform init
Initializing modules...
- module.vpc
  Getting source "git::https://git.example.com/<group>/ProjectA//modules/vpc"
- module.public-subnets
  Getting source "git::https://git.example.com/<group>/ProjectA//modules/subnets"
- module.private-subnets
  Getting source "git::https://git.example.com/<group>/ProjectA//modules/subnets"
- module.nat
  Getting source "git::https://git.example.com/<group>/ProjectA//modules/nat"
- module.public-subnets-rt
  Getting source "git::https://git.example.com/<group>/ProjectA//modules/routes/public"
...
- module.s3_bucket
  Getting source "git::https://git.example.com/<group>/ProjectA//modules/s3"

Error downloading modules: Error loading modules: error downloading 'https://git.example.com/<group>/ProjectA': /usr/bin/git exited with 128: Cloning into '.terraform/modules/a839ef67cd80c00e3439361c5830c57c'...
```

I run GitLab in Kubernetes which in turn is deployed in AWS via [kops](https://icicimov.github.io/blog/virtualization/Kubernetes-Cluster-in-AWS-with-Kops/). Thus the runners are launched as Docker containers and I could not get any log out of them. They also error and exit too quickly thus making any kind of troubleshooting impossible. As a result I came up with the workaround under the `modules` stage (using sparse checkout) and set all modules to read from local source instead:

```
module "vpn" {
    source = "./modules/vpn"
    ...
}
```

and left the troubleshooting for another day. The below image shows the pipeline execution:

[![Pipeline execution](/blog/images/terraform-pipeline.png)](/blog/images/terraform-pipeline.png "Pipeline execution")

At the end of the `plan` stage we can see 111 resources are ready to get created once we manually activate the `apply` stage:

```
...
Plan: 111 to add, 0 to change, 0 to destroy.

------------------------------------------------------------------------

This plan was saved to: vpc.tfplan

To perform exactly these actions, run the following command to apply:
    terraform apply "vpc.tfplan"

Releasing state lock. This may take a few moments...
Creating cache default...
modules: found 164 matching files                  
Archive is up to date!                             
Created cache
Uploading artifacts...
vpc.tfplan: found 1 matching files                 
Uploading artifacts to coordinator... ok
Job succeeded
```

Then we manually run the `plan` stage which creates a complete VPC with all our resources and services deployed and ready for testing:

[![Pipeline apply stage](/blog/images/terraform-pipeline-apply.png)](/blog/images/terraform-pipeline-apply.png "Pipeline apply stage")

When done we run the `destroy` stage to well destroy the whole infrastructure:

[![Pipeline destroy stage](/blog/images/terraform-pipeline-destroy.png)](/blog/images/terraform-pipeline-destroy.png "Pipeline destroy stage")

## Source project CI/CD setup

Now to `PrrojectA`, the source project, setup. First we crate a `Trigger` in `ProjectB` under `Settings->CI/CD->Pipeline triggers` and copy the token value into a `TOKEN` variable in `ProjectA`. Then the pipeline itself is simple and looks like this:

```yaml
image: igoratencompass/curl:alpine

stages:
  - vpc_test_downstream

# trigger the ProjectB pipeline
trigger_pipeline_in_e2e:
  stage: vpc_test_downstream
  script:
    - curl --version
    # below would had been nice but is only available in Gitlab Premium
    #- "curl -sS -X POST --form token=${CI_JOB_TOKEN} --form ref=master https://git.example.com/api/v4/projects/<ProjectB-id>/trigger/pipeline"
    - "curl -sS -X POST --form token=${TOKEN} --form ref=master https://git.example.com/api/v4/projects/<ProjectB-id>/trigger/pipeline"
  only:
    refs:
      - master
      - tags
    changes:
      - modules/*
      - modules/**/*
```
So only when I make changes to the `modules` directory and tag a release or push to master this pipeline will trigger the `ProjectB`'s pipeline. The screen shot below shows the `ProjectB`'s pipeline when this happens (notice the triggered annotations for the jobs):

[![Pipeline triggers](/blog/images/terraform-triggers.png)](/blog/images/terraform-triggers.png "Pipeline triggers")