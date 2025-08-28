#############################################
# IAM Role for Athena Query Lambda
#############################################
resource "aws_iam_role" "lambda_athena_role" {
  name = "lambda-athena-query-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

#############################################
# Attach necessary permissions
#############################################
# Allow Athena query execution
resource "aws_iam_role_policy_attachment" "lambda_athena" {
  role       = aws_iam_role.lambda_athena_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonAthenaFullAccess"
}

# Give full S3 access (needed for Athena + Lambda copy_object)
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_athena_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Allow Lambda to write logs
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_athena_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

#############################################
# Pre-create Athena Query Results Folder
#############################################
resource "aws_s3_object" "athena_results_prefix" {
  bucket = "damao-cpu-metrics"
  key    = "athena-query-results/"
}

#############################################
# Lambda Function
#############################################
resource "aws_lambda_function" "athena_query" {
  function_name    = "athena_query"
  filename         = "${path.module}/athena_query_lambda/function.zip"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_athena_role.arn
  source_code_hash = filebase64sha256("${path.module}/athena_query_lambda/function.zip")

  timeout = 30

  environment {
    variables = {
      ATHENA_DATABASE  = "cpu_metrics"
      ATHENA_OUTPUT_S3 = "s3://damao-cpu-metrics/athena-query-results/"
    }
  }
}

#############################################
# API Gateway v2 (HTTP API)
#############################################
resource "aws_apigatewayv2_api" "athena_api" {
  name          = "athena-query-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.athena_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.athena_query.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "athena_route" {
  api_id    = aws_apigatewayv2_api.athena_api.id
  route_key = "POST /query"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

#############################################
# Allow API Gateway to Invoke Lambda
#############################################
resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.athena_query.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.athena_api.execution_arn}/*/*"
}

#############################################
# Default Stage for Auto Deploy
#############################################
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.athena_api.id
  name        = "$default"
  auto_deploy = true
}

#############################################
# Output API Endpoint
#############################################
output "athena_api_endpoint" {
  value       = aws_apigatewayv2_api.athena_api.api_endpoint
  description = "Use this URL in Looker Studio"
}

resource "aws_apigatewayv2_route" "athena_get_route" {
  api_id    = aws_apigatewayv2_api.athena_api.id
  route_key = "GET /query"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

