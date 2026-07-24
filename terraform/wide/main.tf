###############################################################################
# Terraform equivalent of cdk/lib/wide-stack.ts (parallel-wide scenario):
# many INDEPENDENT resources, no NAT / no dependency chain.
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

variable "count_each" {
  type    = number
  default = 8
}

variable "prefix" {
  type    = string
  default = "bench-tf-wide"
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "b" {
  count         = var.count_each
  bucket_prefix = "${var.prefix}-${count.index}-"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "b" {
  count  = var.count_each
  bucket = aws_s3_bucket.b[count.index].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "t" {
  count        = var.count_each
  name         = "${var.prefix}-t-${count.index}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_sqs_queue" "q" {
  count                     = var.count_each
  name                      = "${var.prefix}-q-${count.index}"
  message_retention_seconds = 345600
}

resource "aws_sns_topic" "s" {
  count = var.count_each
  name  = "${var.prefix}-s-${count.index}"
}

resource "aws_ssm_parameter" "p" {
  count = var.count_each
  name  = "/${var.prefix}/p-${count.index}"
  type  = "String"
  value = "bench-wide-${count.index}"
}

resource "aws_cloudwatch_log_group" "l" {
  count             = var.count_each
  name              = "/${var.prefix}/lg-${count.index}"
  retention_in_days = 7
}
