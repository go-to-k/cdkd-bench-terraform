###############################################################################
# Terraform equivalent of cdk/lib/ec2-stack.ts:
# VPC (1 AZ, public only) + SecurityGroup + IAM Role + InstanceProfile +
# 3 x t3.micro with an explicit encrypted gp3 root volume.
#
# Completion definition: `aws_instance` waits for the instance to reach
# `running`, which is what cdkd and CloudFormation do too. The provider offers
# NO opt-out (there is no `wait_for_*` argument on aws_instance), so the
# fire-and-forget column is cdkd-only and the results table reports N/A for
# Terraform rather than leaving the cell blank.
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "bench-tf-ec2"
}

variable "instance_count" {
  type    = number
  default = 3
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Same source CDK's MachineImage.latestAmazonLinux2023() resolves: the public
# SSM parameter for the latest AL2023 x86_64 AMI. Using the same parameter on
# both sides keeps the image identical rather than merely similar.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-public" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "instance" {
  name        = "${var.prefix}-sg"
  description = "cdkd-bench ec2 scenario"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from inside the VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# One instance profile PER INSTANCE, which is not how a Terraform user would
# normally write this (one shared profile would do). It matches CDK: the L2
# `ec2.Instance` construct always creates its own InstanceProfile, even when
# several instances share one role. Keeping the counts equal means neither side
# is carrying resources the other does not -- the same parity rule the
# serverless scenario's SQS permission adjustment follows.
resource "aws_iam_instance_profile" "instance" {
  count = var.instance_count
  name  = "${var.prefix}-profile-${count.index}"
  role  = aws_iam_role.instance.name
}

resource "aws_instance" "this" {
  count = var.instance_count

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance[count.index].name
  user_data              = "#!/bin/bash\necho cdkd-bench ec2 >/var/log/cdkd-bench.log\n"

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.prefix}-${count.index}" }
}

output "instance_ids" {
  value = aws_instance.this[*].id
}
output "vpc_id" {
  value = aws_vpc.this.id
}
