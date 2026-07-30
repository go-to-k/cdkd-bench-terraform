###############################################################################
# Terraform equivalent of cdk/lib/cloudfront-stack.ts:
# S3 origin + CloudFront distribution with Origin Access Control (OAC).
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
  default = "bench-tf-cf"
}

# The completion definition for this scenario. true (the provider's own
# default) blocks until the distribution reaches `Deployed`, which is what cdkd
# and CloudFormation do by default too. false returns as soon as the
# distribution is created, which is Terraform's counterpart to
# `cdkd deploy --no-wait`.
#
# It was left unset (i.e. true) in the first published run, so the results
# table showed `cdkd --no-wait` at 17.8s against Terraform's 191.1s and read as
# a capability only cdkd has. It is not; it was a measurement gap.
variable "wait_for_deployment" {
  type    = bool
  default = true
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "origin" {
  bucket_prefix = "${var.prefix}-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "origin" {
  bucket                  = aws_s3_bucket.origin.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "origin" {
  bucket = aws_s3_bucket.origin.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "cdkd-bench cloudfront"
  default_root_object = "index.html"
  wait_for_deployment = var.wait_for_deployment

  origin {
    domain_name              = aws_s3_bucket.origin.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    # CachingOptimized managed policy id (matches CDK's default behavior)
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "origin" {
  bucket = aws_s3_bucket.origin.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.origin.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
        }
      }
    }]
  })
}

output "distribution_domain" {
  value = aws_cloudfront_distribution.this.domain_name
}
output "origin_bucket_name" {
  value = aws_s3_bucket.origin.bucket
}
