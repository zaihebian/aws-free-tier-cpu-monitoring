#############################################
# Provider, region, and default tags
#############################################
provider "aws" {
  region = "us-east-1"

  # For clarity/cost tracking
  default_tags {
    tags = {
      Project = "cpu-monitoring"
      Owner   = "parker"
      Env     = "demo"
    }
  }
}

#############################################
# Inputs (edit the bucket name)
#############################################
variable "metrics_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for CSV outputs"
  default     = "damao-cpu-metrics" # <-- must be globally unique and lowercase
}

#############################################
# Networking: use default VPC + Security Group
# - No SSH ingress (Session Manager will be used)
# - Allow all egress so instance can reach AWS services
#############################################
resource "aws_default_vpc" "default" {}

resource "aws_security_group" "instance" {
  name        = "ec2-no-ingress"
  description = "No inbound; allow all outbound"
  vpc_id      = aws_default_vpc.default.id

  # No ingress blocks (closed inbound)

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#############################################
# AMI (Amazon Linux 2023, latest x86_64)
# - Avoids hardcoding AMI IDs
#############################################
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

#############################################
# SSM for EC2 access (no SSH)
# - Role + Instance Profile to register with Systems Manager
#############################################
resource "aws_iam_role" "ec2_ssm_role" {
  name = "ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action   = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "ec2-ssm-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

#############################################
# EC2 instance to monitor
# - monitoring = false (5-minute metrics)
#############################################
resource "aws_instance" "monitoring_ec2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t2.micro"
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm_profile.name
  monitoring             = false  # basic monitoring (5-min)

  tags = { Name = "MonitoringEC2" }
}

#############################################
# S3 bucket to store daily CSVs
# - Keep it simple (no extra hardening as requested)
#############################################
resource "aws_s3_bucket" "metrics_bucket" {
  bucket = var.metrics_bucket_name
}

resource "aws_s3_bucket_public_access_block" "metrics_bucket_block" {
  bucket                  = aws_s3_bucket.metrics_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#############################################
# Lambda execution role
# - Minimal: logs + read CloudWatch metrics + read EC2 describe
# - Inline policy: PutObject to the metrics bucket
#############################################
resource "aws_iam_role" "lambda_exec_role" {
  # omit explicit name to avoid collisions in shared accounts
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action   = "sts:AssumeRole"
    }]
  })
}

# Logs: least-privileged managed policy for Lambda logging
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read CloudWatch Metrics
resource "aws_iam_role_policy_attachment" "lambda_cloudwatch_read" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

# Read EC2 (for LaunchTime logic)
resource "aws_iam_role_policy_attachment" "lambda_ec2_read" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

# Write daily CSVs to S3 (no ACLs needed)
resource "aws_iam_role_policy" "lambda_s3_put" {
  name = "lambda-s3-put"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["s3:PutObject"],
      Resource = "${aws_s3_bucket.metrics_bucket.arn}/*"
    }]
  })
}


#############################################
# Lambda function
# - Python 3.12
# - PERIOD_SECONDS = 300 (matches EC2 basic monitoring)
#############################################
resource "aws_lambda_function" "analyze_metrics" {
  function_name    = "analyze_metrics"
  filename         = "${path.module}/lambda/function.zip"
  handler          = "analyze_metrics.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_exec_role.arn
  source_code_hash = filebase64sha256("${path.module}/lambda/function.zip")
  timeout          = 30

  environment {
    variables = {
      BUCKET_NAME    = aws_s3_bucket.metrics_bucket.bucket
      INSTANCE_ID    = aws_instance.monitoring_ec2.id
      PERIOD_SECONDS = "300"  # 5-min granularity (basic monitoring)
    }
  }
}

#############################################
# EventBridge (CloudWatch Events) schedule
# - Run the Lambda once per day to limit S3 writes
#############################################
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  name                = "analyze-metrics-daily"
  schedule_expression = "rate(24 hours)"
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.lambda_schedule.name
  target_id = "analyze_lambda"
  arn       = aws_lambda_function.analyze_metrics.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyze_metrics.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}

#############################################
# Outputs
#############################################
output "bucket_name" {
  value       = aws_s3_bucket.metrics_bucket.bucket
  description = "S3 bucket receiving the daily CSVs"
}

output "lambda_name" {
  value       = aws_lambda_function.analyze_metrics.function_name
  description = "Lambda function name"
}

output "instance_id" {
  value       = aws_instance.monitoring_ec2.id
  description = "Monitored EC2 instance ID"
}