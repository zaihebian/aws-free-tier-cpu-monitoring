#############################################
# Provider + Region
#############################################
provider "aws" {
  region = "us-east-1"
}

#############################################
# Inputs (edit as needed)
#############################################
# Change this to a unique S3 bucket name (required).
variable "metrics_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for CSV outputs"
  default     = "damao-cpu-metrics"
}

#############################################
# SSH key pair for EC2 (public key only)
# - We generate 'my-key' in Codespace and commit only 'my-key.pub'
#############################################
resource "aws_key_pair" "my_key" {
  key_name   = "my-key"
  public_key = file("${path.module}/my-key.pub")
}

#############################################
# Networking (use default VPC) + Security Group
# - Opens SSH (22) to the world for demo. Lock down in real use.
#############################################
resource "aws_default_vpc" "default" {}

resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh"
  description = "Allow SSH inbound traffic"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#############################################
# EC2 instance to monitor
# - monitoring = true enables 1-minute metrics (detailed monitoring).
#   If you set it false, use 5-minute period in the Lambda env.
#############################################
resource "aws_instance" "monitoring_ec2" {
  ami                    = "ami-0c02fb55956c7d316" # Amazon Linux 2 in us-east-1
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.my_key.key_name
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]
  monitoring             = true

  tags = {
    Name = "MonitoringEC2"
  }
}

#############################################
# S3 bucket to store daily CSVs
# - Public access blocked by default.
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
# IAM role for Lambda
# - Trust policy: allow Lambda service to assume this role.
#############################################
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

#############################################
# IAM policies for the Lambda role
# - CloudWatch Logs: write function logs
# - CloudWatch ReadOnly: read metrics
# - EC2 ReadOnly: read instance LaunchTime (for smart start window)
# - S3 inline policy: allow PutObject into the metrics bucket
#############################################
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_cloudwatch_read" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_ec2_read" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

resource "aws_iam_role_policy" "lambda_s3_put" {
  name = "lambda-s3-put"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect: "Allow",
      Action = ["s3:PutObject", "s3:PutObjectAcl"],
      Resource = "${aws_s3_bucket.metrics_bucket.arn}/*"
    }]
  })
}

#############################################
# Lambda function
# - Zip file lives at terraform/lambda/function.zip
# - Env vars tell Python which bucket/instance/period to use
#############################################
resource "aws_lambda_function" "analyze_metrics" {
  function_name    = "analyze_metrics"
  filename         = "${path.module}/lambda/function.zip"
  handler          = "analyze_metrics.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_exec_role.arn
  source_code_hash = filebase64sha256("${path.module}/lambda/function.zip")

  environment {
    variables = {
      BUCKET_NAME    = aws_s3_bucket.metrics_bucket.bucket
      INSTANCE_ID    = aws_instance.monitoring_ec2.id
      PERIOD_SECONDS = "60"   # use "300" if you disable EC2 detailed monitoring
    }
  }

  # Optional: larger timeout if you later add more queries
  timeout = 30
}

#############################################
# EventBridge (CloudWatch Events) schedule
# - Run the Lambda once per day to keep S3 PUTs very low
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
# Useful outputs
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
