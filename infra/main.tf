terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    random  = { source = "hashicorp/random" }
    archive = { source = "hashicorp/archive" }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "inferno-users"
}

locals {
  tags = { Project = "inferno-bank", Stack = "catalog" }
}

# -------------------- 1. VPC completa --------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Subnets públicas y privadas (dos AZs)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${var.name_prefix}-public-a" })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${var.name_prefix}-public-b" })
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "${var.aws_region}a"
  tags = merge(local.tags, { Name = "${var.name_prefix}-private-a" })
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "${var.aws_region}b"
  tags = merge(local.tags, { Name = "${var.name_prefix}-private-b" })
}

# NAT Gateway para que las Lambdas salgan a Internet
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = merge(local.tags, { Name = "${var.name_prefix}-nat" })
}

# Tablas de rutas
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-rt-public" })
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-rt-private" })
}

resource "aws_route_table_association" "priv_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "priv_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# SGs
resource "aws_security_group" "lambda_sg" {
  name   = "${var.name_prefix}-lambda-sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-lambda-sg" })
}

resource "aws_security_group" "redis_sg" {
  name   = "${var.name_prefix}-redis-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_sg.id]
    description     = "Allow Redis from Lambda SG"
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-redis-sg" })
}

# -------------------- 2. Redis --------------------
resource "random_password" "redis_auth" {
  length  = 32
  special = false
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.name_prefix}-redis-subnets"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id  = "${var.name_prefix}-catalog-redis"
  description           = "Redis for Catalog"
  engine                = "redis"
  engine_version        = "7.1"
  node_type             = var.redis_node_type

  num_node_groups         = 1
  replicas_per_node_group = 0

  port                           = 6379
  at_rest_encryption_enabled     = true
  transit_encryption_enabled     = true
  auth_token                     = random_password.redis_auth.result
  auth_token_update_strategy     = "ROTATE"
  automatic_failover_enabled     = false
  multi_az_enabled               = false

  security_group_ids = [aws_security_group.redis_sg.id]
  subnet_group_name  = aws_elasticache_subnet_group.redis.name

  tags = local.tags
}

# -------------------- 3. S3 bucket --------------------
resource "aws_s3_bucket" "catalog" {
  bucket = "${var.name_prefix}-catalog-uploads"
  tags   = merge(local.tags, { Name = "${var.name_prefix}-catalog-uploads" })
}

resource "aws_s3_bucket_versioning" "catalog" {
  bucket = aws_s3_bucket.catalog.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -------------------- 4. IAM + Lambdas --------------------
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-catalog-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
  tags               = local.tags
}

# Logs básicos
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Acceso a VPC (ENIs) para Lambdas en subnets privadas
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Acceso S3 para catalog-update
data "aws_iam_policy_document" "s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.catalog.arn}/*"]
  }
}

resource "aws_iam_policy" "s3" {
  name   = "${var.name_prefix}-catalog-s3"
  policy = data.aws_iam_policy_document.s3.json
}

resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.s3.arn
}

# Código placeholder (ZIP inline)
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"

  source_content = <<-EOT
  exports.handler = async () => {
    return {
      statusCode: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ok: true })
    };
  };
  EOT

  source_content_filename = "index.js"
}

resource "aws_lambda_function" "catalog_get" {
  function_name = "${var.name_prefix}-catalog-get"
  role          = aws_iam_role.lambda.arn
  runtime       = "nodejs20.x"
  handler       = "index.handler"
  filename      = data.archive_file.lambda_zip.output_path
  timeout       = 10
  memory_size   = 256

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      REDIS_ENDPOINT = aws_elasticache_replication_group.redis.primary_endpoint_address
      REDIS_PORT     = "6379"
      REDIS_TLS      = "true"
      # Para prod: pasar token vía Secrets Manager/SSM y NO en variables de entorno planas
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_iam_role_policy_attachment.s3_attach,
    aws_iam_role_policy_attachment.lambda_vpc_access
  ]
}

resource "aws_lambda_function" "catalog_update" {
  function_name = "${var.name_prefix}-catalog-update"
  role          = aws_iam_role.lambda.arn
  runtime       = "nodejs20.x"
  handler       = "index.handler"
  filename      = data.archive_file.lambda_zip.output_path
  timeout       = 30
  memory_size   = 512

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      CATALOG_BUCKET_NAME = aws_s3_bucket.catalog.bucket
      REDIS_ENDPOINT      = aws_elasticache_replication_group.redis.primary_endpoint_address
      REDIS_PORT          = "6379"
      REDIS_TLS           = "true"
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_iam_role_policy_attachment.s3_attach,
    aws_iam_role_policy_attachment.lambda_vpc_access
  ]
}

# -------------------- 5. API Gateway --------------------
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.name_prefix}-catalog-api"
  protocol_type = "HTTP"
  tags          = local.tags
}

resource "aws_apigatewayv2_integration" "get" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.catalog_get.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "update" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.catalog_update.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /catalog"
  target    = "integrations/${aws_apigatewayv2_integration.get.id}"
}

resource "aws_apigatewayv2_route" "update" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /catalog/update"
  target    = "integrations/${aws_apigatewayv2_integration.update.id}"
}

resource "aws_apigatewayv2_stage" "stage" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "prod"
  auto_deploy = true
  tags        = local.tags
}

resource "aws_lambda_permission" "api_get" {
  statement_id  = "AllowInvokeGet"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.catalog_get.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_update" {
  statement_id  = "AllowInvokeUpdate"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.catalog_update.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
