---
type: posts
header:
  teaser: 'Device-Mesh.jpg'
title: 'Using data source to mitigate lack of intermediate variables and interpolation'
categories: 
  - DevOps
tags: [terraform]
date: 2016-8-26
---

Just something I dug out in the Terraform forum and would like to keep as a reminder for the future. Terraform will not allow us to do something like this:

```
variable project_name { default = "ane" }
variable some_name { default = "something.${var.project_name}" }
```

It will complain about variable interpolation inside another variable. Lets create couple of files:

```
$ tree .
.
├── test.tf
└── test.tfvars
```

and test the workaround:

```
$ cat test.tf
variable "project_name" { 
    default = "ane" 
}

# Defaults for discovery
variable "discovery" {
    default = {
        backend = "consul"
        port    = 8500
    }
}

# Data source is used to mitigate lack of intermediate variables and interpolation
data "null_data_source" "discovery" {
    inputs = {
        backend = "${var.discovery["backend"]}"
        port    = "${var.discovery["port"]}"
        dns     = "${lookup(var.discovery, "dns", "consul.${var.project_name}")}"
    }
}

output "discovery" {
    value = "${data.null_data_source.discovery.inputs}"
}

```

And second one to pass a value on just to confirm it works this way too:

```
$ cat test.tfvars 
project_name = "igor"
```

Result from run:

```
$ terraform apply -var-file test.tfvars 
data.null_data_source.discovery: Refreshing state...

Apply complete! Resources: 0 added, 0 changed, 0 destroyed.

Outputs:

discovery = {
  backend = consul
  dns = consul.igor
  port = 8500
}
$ 
```

So, we were able to set the dns key of the `discovery` Null Data Source via intermediate variable using variable interpolation which is something that Terraform wouldn't let us normally do (but works for this data source). And now, instead of using the real `discovery` variable we have to use the null data source instead, for example we would use `"${data.null_data_source.discovery.input.dns}"` as parameter to access the dns name.