---
type: posts
title: 'Building VPC with Terraform in Amazon AWS'
category: Server
tags: [aws, terraform]
---

[Terraform](https://www.terraform.io) is a tool for automating infrastructure management. It can be used for a simple task like managing single application instance or more complex ones like managing entire datacenter or virtual cloud. The infrastructure Terraform can manage includes low-level components such as compute instances, storage, and networking, as well as high-level components such as DNS entries, SaaS features and others. It is a great tool to have in a DevOps environment and I find it very powerful but simple to use when it comes to managing infrastructure as a code (IaaC). And the best thing about it is the support for various platforms and providers like AWS, Digital Ocean, OpenStack, Microsoft Azure, Google Cloud etc. meaning you get to use the same toll to manage your infrastructure on any of these cloud providers. See the [Providers](https://www.terraform.io/docs/providers/index.html) page for full list.

Terraform uses configuration files to describe the components of the infrastructure we want to build and manage. It generates an execution plan describing what it will do to reach the desired state, and then executes it to build the `terraform.tfstate` file by default. This state file is extremely important; it maps various resource metadata to actual resource IDs so that Terraform knows what it is managing. This file must be saved and distributed to anyone who might run Terraform against the very VPC infrastructure we created so storing this in GitHub repository is the best way to go in order to share a project.

To install terraform follow the simple steps from the install web page [Getting Started](https://www.terraform.io/intro/getting-started/install.html)

## Notes before we start

First let me mention that the below code has been adjusted to work with the latest Terraform and has been successfully tested with version `0.7.4`. It has been running for long time now and been used many times to create production VPC's in AWS. It's been based on `CloudFormation` templates I've written for the same purpose at some point in 2014 during the quest of converting our infrastructure into code.

What is this going to do is:

* Create a multi tier VPC (Virtual Private Cloud) in specific AWS region
* Create 2 Private and 1 Public Subnet in the specific VPC CIDR
* Create Routing Tables and attach them to the appropriate subnets
* Create a NAT instance with ASG (Auto Scaling Group) to server as default gateway for the private subnets
* Create Security Groups to use with EC2 instances we create
* Create SNS notifications for Auto Scaling events

This is a step-by-step walk through, the source code will be made available at some point.

## Building Infrastructure

After setting up the binaries we create an empty directory that will hold the new project. First thing we do is tell terraform which provider we are going to use. Since we are building Amazon AWS infrastructure we create a `.tfvars` file with our AWS IAM API credentials. For example, `provider-credentials.tfvars` with the following content: 

```
provider = {
	access_key = "<AWS_ACCESS_KEY>"
	secret_key = "<AWS_SECRET_KEY>"
	region = "ap-southeast-2"
}
```

We make sure the API credentials are for user that has full permissions to create, read and destroy infrastructure in our AWS account. Check the IAM user and its roles to confirm this is the case.

Then we create a `.tf` file where we create our first resource called `provider`. Lets name the file `provider-config.tf` and put the following content:

```
provider "aws" {
    access_key = "${var.provider["access_key"]}"
    secret_key = "${var.provider["secret_key"]}"
    region     = "${var.provider["region"]}"
}
```

for our AWS provider type. 

Then we create a `.tf` file `vpc_environment.tf` where we put all essential variables needed to build the VPC, like VPC CIDR, AWS zone and regions, EC2 instance type and the ssh key and other AWS related parameters:

```
/*=== VARIABLES ===*/
variable "provider" {
    type = "map"
    default = {
        access_key = "unknown"
        secret_key = "unknown"
        region     = "unknown"
    }
}

variable "vpc" {
    type    = "map"
    default = {
        "tag"         = "unknown"
        "cidr_block"  = "unknown"
        "subnet_bits" = "unknown"
        "region"      = "unknown"
        "owner_id"    = "unknown"
        "sns_topic"   = "unknown"
    }
}

variable "azs" {
    type = "map"
    default = {
        "ap-southeast-2" = "ap-southeast-2a,ap-southeast-2b,ap-southeast-2c"
        "eu-west-1"      = "eu-west-1a,eu-west-1b,eu-west-1c"
        "us-west-1"      = "us-west-1b,us-west-1c"
        "us-west-2"      = "us-west-2a,us-west-2b,us-west-2c"
        "us-east-1"      = "us-east-1c,us-west-1d,us-west-1e"
    }
}

variable "instance_type" {
    default = "t1.micro"
}

variable "key_name" {
    default = "unknown"
}

variable "nat" {
    type    = "map"
    default = {
        ami_image         = "unknown"
        instance_type     = "unknown"
        availability_zone = "unknown"
        key_name          = "unknown"
        filename          = "userdata_nat_asg.sh"
    }
}

/* Ubuntu Trusty 14.04 LTS (x64) */
variable "images" {
    type    = "map"
    default = {
        eu-west-1      = "ami-47a23a30"
        ap-southeast-2 = "ami-6c14310f"
        us-east-1      = "ami-2d39803a"
        us-west-1      = "ami-d732f0b7"
        us-west-2      = "ami-d732f0b7"
    }
}

variable "env_domain" {
    type    = "map"
    default = {
        name    = "unknown"
        zone_id = "unknown"
    }
}
```

I have created most of the variables as generic and then passing on their values via separate `.tfvars` file `vpc_environment.tfvars`:  

```
vpc = {
    tag                   = "TFTEST"
    region                = "ap-southeast-2"
    owner_id              = "<owner-id>"
    cidr_block            = "10.99.0.0/20"
    subnet_bits           = "4"
    sns_topic             = "arn:aws:sns:ap-southeast-2:<owner-id>:<topic-name>"
}
key_name                  = "<ssh-key>"
nat.instance_type         = "m3.medium"
env_domain = {
    name                  = "mydomain.com"
    zone_id               = "<zone-id>"
}
```

Terraform does not support (yet) interpolation by referencing another variable in a variable name nor usage of an array as an element of a map. These are couple of shortcomings but If you have used AWS's CloudFormation you would have faced similar "issues". After all these tools are not really a programming language so we have to accept them as they are and try to make the best of it.

We can see I have separated the provider stuff from the rest of it including the resource so I can easily share my project without exposing sensitive data. For example I can create GitHub repository out of my project directory and put the `provider-credentials.tfvariables` file in `.gitignore` so it never gets accidentally uploaded.

Now is time to do the first test. After substituting all values in `<>` with real ones we run:

```
$ terraform plan -var-file provider-credentials.tfvars -var-file vpc_environment.tfvars -out vpc.tfplan 
```

inside the directory and check the output. If this goes without any errors then we can proceed to next step, otherwise we have to go back and fix the errors terraform has printed out. To apply the planned changes then we run:

```
$ terraform apply vpc.tfplan
```

but it's too early for that at this stage since we have nothing to apply yet.

We can start creating resources now, starting with a VPC, subnets and IGW (Internet Gateway). We want our VPC to be created in a region with 3 AZ's (Availability Zones) so we can spread our future instance nicely for HA. We create a new `.tf` file `vpc.tf`:

```
/*=== VPC AND SUBNETS ===*/
resource "aws_vpc" "environment" {
    cidr_block           = "${var.vpc["cidr_block"]}"
    enable_dns_support   = true
    enable_dns_hostnames = true 
    tags {
        Name        = "VPC-${var.vpc["tag"]}"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_internet_gateway" "environment" {
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-internet-gateway"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_subnet" "public-subnets" {
    vpc_id            = "${aws_vpc.environment.id}"
    count             = "${length(split(",", lookup(var.azs, var.provider["region"])))}"
    cidr_block        = "${cidrsubnet(var.vpc["cidr_block"], var.vpc["subnet_bits"], count.index)}"
    availability_zone = "${element(split(",", lookup(var.azs, var.provider["region"])), count.index)}"
    tags {
        Name          = "${var.vpc["tag"]}-public-subnet-${count.index}"
        Environment   = "${lower(var.vpc["tag"])}"
    }
    map_public_ip_on_launch = true
}

resource "aws_subnet" "private-subnets" {
    vpc_id            = "${aws_vpc.environment.id}"
    count             = "${length(split(",", lookup(var.azs, var.provider["region"])))}"
    cidr_block        = "${cidrsubnet(var.vpc["cidr_block"], var.vpc["subnet_bits"], count.index + length(split(",", lookup(var.azs, var.provider["region"]))))}"
    availability_zone = "${element(split(",", lookup(var.azs, var.provider["region"])), count.index)}"
    tags {
        Name          = "${var.vpc["tag"]}-private-subnet-${count.index}"
        Environment   = "${lower(var.vpc["tag"])}"
        Network       = "private"
    }
}

resource "aws_subnet" "private-subnets-2" {
    vpc_id            = "${aws_vpc.environment.id}"
    count             = "${length(split(",", lookup(var.azs, var.provider["region"])))}"
    cidr_block        = "${cidrsubnet(var.vpc["cidr_block"], var.vpc["subnet_bits"], count.index + (2 * length(split(",", lookup(var.azs, var.provider["region"])))))}"
    availability_zone = "${element(split(",", lookup(var.azs, var.provider["region"])), count.index)}"
    tags {
        Name          = "${var.vpc["tag"]}-private-subnet-2-${count.index}"
        Environment   = "${lower(var.vpc["tag"])}"
        Network       = "private"
    }
}
```

This will create a VPC for us with 3 sets of subnets, 2 private and 1 public (meaning will have the IGW as default gateway). For the private subnets we need to create a NAT instance to be used as internet gateway. We can create a new `.tf` file `vpc_nat_instance.tf` lets say where we create the resource:

```
/*== NAT INSTANCE IAM PROFILE ==*/
resource "aws_iam_instance_profile" "nat" {
    name  = "${var.vpc["tag"]}-nat-profile"
    roles = ["${aws_iam_role.nat.name}"]
}

resource "aws_iam_role" "nat" {
    name = "${var.vpc["tag"]}-nat-role"
    path = "/"
    assume_role_policy = <<EOF
{
    "Version": "2008-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {"AWS": "*"},
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

resource "aws_iam_policy" "nat" {
    name = "${var.vpc["tag"]}-nat-policy"
    path = "/"
    description = "NAT IAM policy"
    policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeInstances",
                "ec2:ModifyInstanceAttribute",
                "ec2:DescribeSubnets",
                "ec2:DescribeRouteTables",
                "ec2:CreateRoute",
                "ec2:ReplaceRoute"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_iam_policy_attachment" "nat" {
    name       = "${var.vpc["tag"]}-nat-attachment"
    roles      = ["${aws_iam_role.nat.name}"]
    policy_arn = "${aws_iam_policy.nat.arn}"
}


/*=== NAT INSTANCE ASG ===*/
resource "aws_autoscaling_group" "nat" {
    name                      = "${var.vpc["tag"]}-nat-asg"
    availability_zones        = "${split(",", lookup(var.azs, var.provider["region"]))}"
    vpc_zone_identifier       = ["${aws_subnet.public-subnets.*.id}"]
    max_size                  = 1
    min_size                  = 1
    health_check_grace_period = 60
    default_cooldown          = 60
    health_check_type         = "EC2"
    desired_capacity          = 1
    force_delete              = true
    launch_configuration      = "${aws_launch_configuration.nat.name}"
    tag {
      key                 = "Name"
      value               = "NAT-${var.vpc["tag"]}"
      propagate_at_launch = true
    }
    tag {
      key                 = "Environment"
      value               = "${lower(var.vpc["tag"])}"
      propagate_at_launch = true
    }
    tag {
      key                 = "Type"
      value               = "nat"
      propagate_at_launch = true
    }
    tag {
      key                 = "Role"
      value               = "bastion"
      propagate_at_launch = true
    }
    lifecycle {
      create_before_destroy = true
    }
}

resource "aws_launch_configuration" "nat" {
    name_prefix                 = "${var.vpc["tag"]}-nat-lc-"
    image_id                    = "${lookup(var.images, var.provider["region"])}"
    instance_type               = "${var.nat["instance_type"]}"
    iam_instance_profile        = "${aws_iam_instance_profile.nat.name}"
    key_name                    = "${var.key_name}"
    security_groups             = ["${aws_security_group.nat.id}"]
    associate_public_ip_address = true
    user_data                   = "${data.template_file.nat.rendered}"
    lifecycle {
      create_before_destroy = true
    }
}

data "template_file" "nat" {
    template = "${file("${var.nat["filename"]}")}"
    vars {
        cidr = "${var.vpc["cidr_block"]}"
    }
}
```

We create the NAT instance in a Auto Scaling group since being a vital part of the infrastructure we want it to be highly available. This means that in case of a failure, the ASG will launch a new one. This instance then needs to configure it self as a gateway for the public subnets for which we create and attach to it an IAM role with specific permissions. Lastly the instance will use the `userdata_nat_asg.sh` file (see the variables file) given to it via `user-data` to setup the routing for the private subnets. The scipt is given below:

```
#!/bin/bash -v
set -e
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
rm -rf /var/lib/apt/lists/*
sed -e '/^deb.*security/ s/^/#/g' -i /etc/apt/sources.list
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -m -qq
apt-get -y install conntrack iptables-persistent nfs-common > /tmp/nat.log
[[ -s $(modinfo -n ip_conntrack) ]] && modprobe ip_conntrack && echo ip_conntrack | tee -a /etc/modules
/sbin/sysctl -w net.ipv4.ip_forward=1
/sbin/sysctl -w net.ipv4.conf.eth0.send_redirects=0
/sbin/sysctl -w net.netfilter.nf_conntrack_max=131072
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.ipv4.conf.eth0.send_redirects=0" >> /etc/sysctl.conf
echo "net.netfilter.nf_conntrack_max=131072" >> /etc/sysctl.conf
/sbin/iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
/sbin/iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP
/sbin/iptables -A INPUT -p tcp --syn -m limit --limit 5/s -i eth0 -j ACCEPT
/sbin/iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
/sbin/iptables -t nat -A POSTROUTING -o eth0 -s ${cidr} -j MASQUERADE
sleep 1
wget -P /usr/local/bin https://s3-ap-southeast-2.amazonaws.com/encompass-public/ha-nat-terraform.sh
[[ ! -x "/usr/local/bin/ha-nat-terraform.sh" ]] && chmod +x /usr/local/bin/ha-nat-terraform.sh
/bin/bash /usr/local/bin/ha-nat-terraform.sh
cat > /etc/profile.d/user.sh <<END
HISTSIZE=1000
HISTFILESIZE=40000
HISTTIMEFORMAT="[%F %T %Z] "
export HISTSIZE HISTFILESIZE HISTTIMEFORMAT
END
sed -e '/^#deb.*security/ s/^#//g' -i /etc/apt/sources.list
exit 0
```

It configures the firewall and the NAT rules and executes the `ha-nat-terraform.sh` script fetched from a S3 bucket.

In the same time we create Security Groups, or instance firewalls in AWS terms, to attach to the subnets and the NAT instance we are going to create:

```
/*=== SECURITY GROUPS ===*/
resource "aws_security_group" "default" {
    name = "${var.vpc["tag"]}-default"
    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["${var.vpc["cidr_block"]}"]
    }
    ingress {
        from_port   = -1
        to_port     = -1
        protocol    = "icmp"
        cidr_blocks = ["${var.vpc["cidr_block"]}"]
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-default-security-group"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_security_group" "nat" {
    name = "${var.vpc["tag"]}-nat"
    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port   = -1
        to_port     = -1
        protocol    = "icmp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port   = 123 
        to_port     = 123
        protocol    = "udp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["${var.vpc["cidr_block"]}"]
    }
    ingress {
        from_port   = 443 
        to_port     = 443 
        protocol    = "tcp"
        cidr_blocks = ["${var.vpc["cidr_block"]}"]
    }
    egress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = -1
        to_port     = -1
        protocol    = "icmp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = 443 
        to_port     = 443 
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = 123 
        to_port     = 123
        protocol    = "udp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = 53 
        to_port     = 53
        protocol    = "udp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = 53
        to_port     = 53
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-nat-security-group"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_security_group" "public" {
    name = "${var.vpc["tag"]}-public"
    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port   = 80 
        to_port     = 80 
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-public-security-group"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_security_group" "private" {
    name = "${var.vpc["tag"]}-private"
    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["${aws_subnet.private-subnets.*.cidr_block}"]
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-private-security-group"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_security_group" "private-2" {
    name = "${var.vpc["tag"]}-private-2"
    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["${aws_subnet.private-subnets-2.*.cidr_block}"]
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-private-2-security-group"
        Environment = "${lower(var.vpc["tag"])}"
    }
}
```

Next we need to sort out the VPC routing, create routing tables and associate them with the subnets. Create a new file `vpc_routing_tables.tf`:

```
/*=== ROUTING TABLES ===*/
resource "aws_route_table" "public-subnet" {
    vpc_id = "${aws_vpc.environment.id}"
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = "${aws_internet_gateway.environment.id}"
    }
    tags {
        Name        = "${var.vpc["tag"]}-public-subnet-route-table"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_route_table_association" "public-subnet" {
    count          = "${length(split(",", lookup(var.azs, var.provider["region"])))}"
    subnet_id      = "${element(aws_subnet.public-subnets.*.id, count.index)}"
    route_table_id = "${aws_route_table.public-subnet.id}"
}

resource "aws_route_table" "private-subnet" {
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-private-subnet-route-table"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_route_table_association" "private-subnet" {
    count          = "${length(split(",", lookup(var.azs, var.provider["region"])))}"
    subnet_id      = "${element(aws_subnet.private-subnets.*.id, count.index)}"
    route_table_id = "${aws_route_table.private-subnet.id}"
}

resource "aws_route_table" "private-subnet-2" {
    vpc_id = "${aws_vpc.environment.id}"
    tags {
        Name        = "${var.vpc["tag"]}-private-subnet-2-route-table"
        Environment = "${lower(var.vpc["tag"])}"
    }
}

resource "aws_route_table_association" "private-subnet-2" {
    count          = "${length(split(",", lookup(var.azs, var.provider["region"])))}"
    subnet_id      = "${element(aws_subnet.private-subnets-2.*.id, count.index)}"
    route_table_id = "${aws_route_table.private-subnet-2.id}"
}
```

To wrap it up I would like to receive some notifications in case of Autoscaling events so we create `vpc_notifications.tf` file:

```
/*=== AUTOSCALING NOTIFICATIONS ===*/
resource "aws_autoscaling_notification" "main" {
  group_names = [
    "${aws_autoscaling_group.nat.name}"
  ]
  notifications  = [
    "autoscaling:EC2_INSTANCE_LAUNCH", 
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR"
  ]
  topic_arn = "${aws_sns_topic.main.arn}"
}

resource "aws_sns_topic" "main" {
  name = "${lower(var.vpc["tag"])}-sns-topic"
}
```

As we further build our infrastructure we will use more Auto Scaling configurations and we can add those to the above resource under `group_names`.

At the end, some outputs we can use if needed:

```
/*=== OUTPUTS ===*/
output "num-zones" {
   value =  "${length(lookup(var.azs, var.provider[region]))}"
}

output "vpc-id" {
  value = "${aws_vpc.environment.id}"
}

output "public-subnet-ids" {
  value = "${join(",", aws_subnet.public-subnets.*.id)}"
}

output "private-subnet-ids" {
  value = "${join(",", aws_subnet.private-subnets.*.id)}"
}

output "private-subnet-2-ids" {
  value = "${join(",", aws_subnet.private-subnets-2.*.id)}"
}

output "autoscaling_notification_sns_topic" {
  value = "${aws_sns_topic.main.id}"
}
```

At the end we run:

```
$ terraform plan -var-file provider-credentials.tfvars -var-file vpc_environment.tfvars -out vpc.tfplan
```

to test and create the plan and then:

```
$ terraform apply vpc.tfplan
```

to create our VPC. When finished we can destroy the infrastructure:

```
$ terraform destroy vpc.tfplan --force
```