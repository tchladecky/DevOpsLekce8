# =============================================================
# Provider & Backend
# =============================================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Bucket vytvoř ručně přes AWS Console (S3 → Create bucket).
    # Jméno musí být globálně unikátní, např. tfstate-<číslo-účtu>-eu-central-1
    bucket = "tfstate-704348945814-us-east-1"
    key    = "ecs-demo/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# =============================================================
# Variables
# =============================================================
variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix pro všechny pojmenované resources"
  default     = "ecs-nginx-demo"
}

variable "image_tag" {
  description = "Docker image tag (naplní CI/CD pipeline)"
  default     = "latest"
}

# =============================================================
# Data sources – existující default VPC
# =============================================================
data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# =============================================================
# ECR Registry
# KROK 1 – nasadit jako první pomocí:
#   terraform apply -target=aws_ecr_repository.nginx
# Pak build/push Docker image, pak terraform apply (zbytek).
# =============================================================
resource "aws_ecr_repository" "nginx" {
  name                 = "${var.project_name}"
  image_tag_mutability = "MUTABLE" # umožňuje přepisovat tag "latest"

  image_scanning_configuration {
    scan_on_push = true # automatický scan na zranitelnosti
  }

  tags = { Name = "${var.project_name}-ecr" }
}

# Lifecycle policy – ponechá posledních 10 tagovaných imagí, smaže netagované starší než 1 den
resource "aws_ecr_lifecycle_policy" "nginx" {
  repository = aws_ecr_repository.nginx.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Smaž netagované image starší než 1 den"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Ponech max 10 tagovaných imagí"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Output ECR URL – potřebné pro docker push v pipeline
output "ecr_repository_url" {
  description = "URL ECR repository (použij pro docker tag a docker push)"
  value       = aws_ecr_repository.nginx.repository_url
}

# =============================================================
# Security Groups
# =============================================================
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from internet"
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

  tags = { Name = "${var.project_name}-alb-sg" }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-sg"
  description = "Allow HTTP inbound from ALB only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from ALB"
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

  tags = { Name = "${var.project_name}-ecs-tasks-sg" }
}

# =============================================================
# Application Load Balancer
# =============================================================
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "nginx" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx.arn
  }
}

# =============================================================
# IAM – ECS Task Execution Role
# Potřebná oprávnění:
#   - stáhnout image z ECR (ecr:GetAuthorizationToken, ecr:BatchGetImage…)
#   - zapisovat logy do CloudWatch
# =============================================================
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project_name}-task-execution-role" }
}

# Managed policy – zahrnuje ECR read + CloudWatch Logs write
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# =============================================================
# IAM – ECS Task Role  (runtime oprávnění samotného kontejneru)
# Pokud kontejner nepotřebuje volat AWS API, nechej prázdný.
# Přidej inline policy, pokud bude potřeba (S3, DynamoDB, …).
# =============================================================
resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project_name}-task-role" }
}

# =============================================================
# CloudWatch Log Group
# =============================================================
resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-logs" }
}

# =============================================================
# ECS Cluster
# =============================================================
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.project_name}-cluster" }
}

# =============================================================
# ECS Task Definition
# image odkazuje na ECR (ne Docker Hub)
# =============================================================
resource "aws_ecs_task_definition" "nginx" {
  family                   = "${var.project_name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  # Execution role – stahuje image z ECR, posílá logy
  execution_role_arn = aws_iam_role.ecs_task_execution.arn

  # Task role – runtime oprávnění kontejneru
  task_role_arn = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "nginx"
      # ECR URL: <account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>
      image     = "${aws_ecr_repository.nginx.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nginx.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = "${var.project_name}-task" }
}

# =============================================================
# ECS Service
# =============================================================
resource "aws_ecs_service" "nginx" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true # nutné v default VPC bez NAT Gateway
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nginx.arn
    container_name   = "nginx"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http]

  tags = { Name = "${var.project_name}-service" }
}

# =============================================================
# Outputs
# =============================================================
output "load_balancer_dns" {
  description = "DNS jméno load balanceru"
  value       = aws_lb.main.dns_name
}

output "load_balancer_url" {
  description = "URL load balanceru (pro curl / browser)"
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecr_login_command" {
  description = "Příkaz pro přihlášení do ECR (docker login)"
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}
