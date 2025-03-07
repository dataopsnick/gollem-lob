terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support = true
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

# Security Groups
resource "aws_security_group" "memorydb" {
  name        = "gollem-memorydb"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

resource "aws_security_group" "lambda" {
  name        = "gollem-lambda"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rust" {
  name        = "gollem-rust"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 50051
    to_port         = 50051
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# MemoryDB Resources
resource "aws_memorydb_parameter_group" "orderbook" {
  family = "memorydb_redis7"
  name   = "gollem-orderbook"

  parameter {
    name  = "active-defrag-threshold-lower"
    value = "10"
  }
  parameter {
    name  = "active-defrag-threshold-upper"
    value = "100"
  }
  parameter {
    name  = "active-defrag-cycle-min"
    value = "25"
  }
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }
  parameter {
    name  = "timeout"
    value = "300"
  }
}

resource "aws_memorydb_subnet_group" "orderbook" {
  name       = "gollem-orderbook"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_memorydb_acl" "orderbook" {
  name       = "gollem-orderbook"
  user_names = [aws_memorydb_user.admin.name]
}

resource "aws_memorydb_user" "admin" {
  user_name     = "admin"
  access_string = "on ~* &* +@all"

  authentication_mode {
    type      = "password"
    passwords = [random_password.memorydb.result]
  }
}

resource "random_password" "memorydb" {
  length  = 32
  special = false
}

resource "aws_memorydb_cluster" "orderbook" {
  name                    = "gollem-orderbook"
  node_type              = "db.t4g.small"
  num_shards             = 2
  num_replicas_per_shard = 1
  port                   = 6379
  
  security_group_ids    = [aws_security_group.memorydb.id]
  subnet_group_name     = aws_memorydb_subnet_group.orderbook.id
  acl_name             = aws_memorydb_acl.orderbook.name
  parameter_group_name = aws_memorydb_parameter_group.orderbook.name

  tls_enabled = true
  
  snapshot_retention_limit = 7
  snapshot_window         = "05:00-09:00"

  tags = {
    Name = "gollem-orderbook"
  }
}

# Service Discovery
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "gollem.internal"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "rust" {
  name = "matcher"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

# Lambda Function
resource "aws_lambda_function" "api" {
  filename         = "../lambda.zip"
  function_name    = "gollem-api"
  role            = aws_iam_role.lambda.arn
  handler         = "index.handler"
  runtime         = var.lambda_runtime
  memory_size     = var.lambda_memory
  timeout         = var.lambda_timeout

  environment {
    variables = {
      MATCHER_HOST = "matcher.${aws_service_discovery_private_dns_namespace.main.name}"
      MATCHER_PORT = "50051"
      MEMORYDB_ENDPOINT = aws_memorydb_cluster.orderbook.cluster_endpoint
      # Add new payment variables
      STRIPE_SECRET_NAME = aws_secretsmanager_secret.stripe.name
      USER_TABLE_NAME = aws_dynamodb_table.user_accounts.name
      LEDGER_TABLE_NAME = aws_dynamodb_table.credit_ledger.name
    }
  }

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# API Gateway
resource "aws_apigatewayv2_api" "main" {
  name          = "gollem-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  
  integration_uri    = aws_lambda_function.api.invoke_arn
  integration_method = "POST"
}

# API Routes
resource "aws_apigatewayv2_route" "generate" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /api/generate"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "orderbook_status" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /api/orderbook/status"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "provider_circuit" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /api/provider/circuit"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "provider_ratelimit" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /api/provider/ratelimit"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "provider_latency" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /api/provider/latency"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "provider_status" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /api/provider/status"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "create_payment_intent" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /api/payments/create-intent"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "stripe_webhook" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /webhooks/stripe"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "get_balance" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /api/payments/balance"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Payment System - DynamoDB Tables
resource "aws_dynamodb_table" "user_accounts" {
  name           = "gollem-user-accounts"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "user_id"
  stream_enabled = true

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "email"
    type = "S"
  }

  global_secondary_index {
    name               = "email-index"
    hash_key           = "email"
    projection_type    = "ALL"
  }

  tags = {
    Name = "gollem-user-accounts"
    Service = "payments"
  }
}

resource "aws_dynamodb_table" "credit_ledger" {
  name           = "gollem-credit-ledger"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "transaction_id"
  range_key      = "timestamp"

  attribute {
    name = "transaction_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  global_secondary_index {
    name               = "user-transactions"
    hash_key           = "user_id"
    range_key         = "timestamp"
    projection_type    = "ALL"
  }

  tags = {
    Name = "gollem-credit-ledger"
    Service = "payments"
  }
}

# Payment System - Secrets Manager
resource "aws_secretsmanager_secret" "stripe" {
  name        = "gollem/stripe"
  description = "Stripe API credentials"
}

# ECS Cluster for Rust Service
resource "aws_ecs_cluster" "main" {
  name = "gollem-cluster"
}

resource "aws_ecs_task_definition" "rust" {
  family                   = "gollem-matcher"
  requires_compatibilities = ["FARGATE"]
  network_mode            = "awsvpc"
  cpu                     = 256
  memory                  = 512

  container_definitions = jsonencode([
    {
      name  = "matcher"
      image = "${aws_ecr_repository.main.repository_url}:latest"
      portMappings = [
        {
          containerPort = 50051
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "RUST_LOG"
          value = "info"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "rust" {
  name            = "gollem-matcher"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.rust.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.rust.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.rust.arn
  }
}

# ECR Repository
resource "aws_ecr_repository" "main" {
  name = var.ecr_repository
}

# Outputs
output "memorydb_endpoint" {
  value     = aws_memorydb_cluster.orderbook.cluster_endpoint
  sensitive = true
}

output "memorydb_reader_endpoint" {
  value     = aws_memorydb_cluster.orderbook.reader_endpoint
  sensitive = true
}

output "memorydb_password" {
  value     = random_password.memorydb.result
  sensitive = true
}

# IAM Roles and Policies
resource "aws_iam_role" "lambda" {
  name = "gollem-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_secrets" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_iam_role" "ecs" {
  name = "gollem-ecs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs" {
  role       = aws_iam_role.ecs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Route Tables and Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Outputs
output "api_endpoint" {
  value = aws_apigatewayv2_api.main.api_endpoint
}

output "memorydb_endpoint" {
  value     = aws_memorydb_cluster.orderbook.cluster_endpoint
  sensitive = true
}

output "memorydb_reader_endpoint" {
  value     = aws_memorydb_cluster.orderbook.reader_endpoint
  sensitive = true
}

output "memorydb_password" {
  value     = random_password.memorydb.result
  sensitive = true
}

output "frontend_domain_name" {  // ADDED OUTPUT
  value = aws_cloudfront_distribution.frontend.domain_name
  description = "CloudFront domain name for the frontend"
}
