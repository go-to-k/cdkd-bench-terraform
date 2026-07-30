###############################################################################
# Terraform equivalent of cdk/lib/ecs-stack.ts:
# VPC (2 AZ, public only) + ECS Cluster + Fargate TaskDefinition +
# Service (desired_count 1) + ALB + TargetGroup + Listener.
#
# Completion definition: this scenario is the one where BOTH tools offer BOTH
# modes, so the results table reports two rows.
#
#   Service ACTIVE (fire and forget) : cdkd default | wait_for_steady_state = false (the provider default)
#   Service steady state             : cdkd --full-wait | wait_for_steady_state = true | CloudFormation default
#
# `var.wait_for_steady_state` selects between them; the default (false) is the
# provider's own default, so a plain `terraform apply` measures the
# fire-and-forget row.
#
# The ALB is a separate wait that BOTH modes pay: `aws_lb` waits for the load
# balancer to become `active`, and so do CloudFormation and (from 0.268) cdkd.
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
  default = "bench-tf-ecs"
}

# false = return once the service is ACTIVE (the aws provider's own default).
# true  = block until the service reaches steady state, which is what
#         CloudFormation always does and what `cdkd --full-wait` opts into.
variable "wait_for_steady_state" {
  type    = bool
  default = false
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
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

# An ALB requires subnets in at least two AZs.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.prefix}-public-${count.index}" }
}

# One route table per subnet rather than one shared table, matching what CDK's
# Vpc construct emits, so the two resource graphs have equal counts.
resource "aws_route_table" "public" {
  count  = 2
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-public-${count.index}" }
}

resource "aws_route" "public_default" {
  count                  = 2
  route_table_id         = aws_route_table.public[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[count.index].id
}

resource "aws_security_group" "alb" {
  name        = "${var.prefix}-alb-sg"
  description = "cdkd-bench ecs alb"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from anywhere"
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
}

resource "aws_security_group" "service" {
  name        = "${var.prefix}-svc-sg"
  description = "cdkd-bench ecs service"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP from the ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  name               = "${var.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "this" {
  name        = "${var.prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    interval            = 10
    timeout             = 5
  }
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_ecs_cluster" "this" {
  name = "${var.prefix}-cluster"
}

resource "aws_cloudwatch_log_group" "service" {
  name              = "/${var.prefix}/service"
  retention_in_days = 1
}

data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# CDK's FargateTaskDefinition creates a task role and, once a log driver is
# attached, an execution role with the managed ECS task-execution policy.
resource "aws_iam_role" "task" {
  name               = "${var.prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role" "execution" {
  name               = "${var.prefix}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.prefix}-task"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([
    {
      name      = "AppContainer"
      image     = "public.ecr.aws/nginx/nginx:stable"
      essential = true
      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "cdkd-bench-ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "this" {
  name            = "${var.prefix}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # The completion definition under test. false (the provider default) returns
  # once the service is ACTIVE; true blocks until steady state.
  wait_for_steady_state = var.wait_for_steady_state

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "AppContainer"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.this]
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}
output "cluster_name" {
  value = aws_ecs_cluster.this.name
}
output "service_name" {
  value = aws_ecs_service.this.name
}
