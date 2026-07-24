###############################################################################
# Terraform equivalent of cdk/lib/serverless-stack.ts:
# Lambda x3 + HTTP API + DynamoDB + SNS/SQS + EventBridge. No VPC.
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.4" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}
variable "prefix" {
  type    = string
  default = "bench-tf-sl"
}

provider "aws" {
  region = var.region
}

resource "aws_dynamodb_table" "t" {
  name         = "${var.prefix}-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_sns_topic" "topic" {
  name = "${var.prefix}-topic"
}
resource "aws_sqs_queue" "q" {
  name                       = "${var.prefix}-queue"
  visibility_timeout_seconds = 60
}
resource "aws_sns_topic_subscription" "sub" {
  topic_arn = aws_sns_topic.topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.q.arn
}
resource "aws_sqs_queue_policy" "q" {
  queue_url = aws_sqs_queue.q.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.q.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.topic.arn } }
    }]
  })
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "archive_file" "fn" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/fn.zip"
}

# Three Lambda functions, each with its own role + DDB access.
locals {
  fns = ["api", "queue", "sched"]
}

resource "aws_iam_role" "fn" {
  for_each           = toset(local.fns)
  name               = "${var.prefix}-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  for_each   = toset(local.fns)
  role       = aws_iam_role.fn[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ddb" {
  statement {
    actions   = ["dynamodb:*"]
    resources = [aws_dynamodb_table.t.arn]
  }
}
resource "aws_iam_role_policy" "ddb" {
  for_each = toset(local.fns)
  role     = aws_iam_role.fn[each.key].id
  policy   = data.aws_iam_policy_document.ddb.json
}

# The queue consumer needs SQS receive permissions for its event source mapping
# (CDK's SqsEventSource grants this automatically; the HCL must do it too).
data "aws_iam_policy_document" "queue_consume" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.q.arn]
  }
}
resource "aws_iam_role_policy" "queue_consume" {
  role   = aws_iam_role.fn["queue"].id
  policy = data.aws_iam_policy_document.queue_consume.json
}

resource "aws_lambda_function" "fn" {
  for_each         = toset(local.fns)
  function_name    = "${var.prefix}-${each.key}"
  role             = aws_iam_role.fn[each.key].arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.t.name }
  }
}

resource "aws_lambda_event_source_mapping" "queue" {
  event_source_arn = aws_sqs_queue.q.arn
  function_name    = aws_lambda_function.fn["queue"].arn
  batch_size       = 10
}

# HTTP API -> api fn
resource "aws_apigatewayv2_api" "api" {
  name          = "bench-serverless"
  protocol_type = "HTTP"
}
resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn["api"].invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "api" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}
resource "aws_apigatewayv2_stage" "api" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}
resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["api"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# EventBridge rule -> sched fn
resource "aws_cloudwatch_event_rule" "sched" {
  name                = "${var.prefix}-rule"
  schedule_expression = "rate(1 hour)"
}
resource "aws_cloudwatch_event_target" "sched" {
  rule = aws_cloudwatch_event_rule.sched.name
  arn  = aws_lambda_function.fn["sched"].arn
}
resource "aws_lambda_permission" "sched" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["sched"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sched.arn
}

output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}
output "table_name" {
  value = aws_dynamodb_table.t.name
}
