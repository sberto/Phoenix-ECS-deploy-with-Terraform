provider "aws" {
  region  = "eu-central-1"
  profile = "CLI"
}

data "http" "public_ip" {
  url = "http://checkip.amazonaws.com/"
}

locals {
  public_ip = trimspace(data.http.public_ip.body)
}

###############
resource "aws_iam_role" "ec2-stuff-role" {
  name = "hello-ec2-stuff-role"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
            "Service": [
                "s3.amazonaws.com",
                "lambda.amazonaws.com",
                "ecs.amazonaws.com",
                "ecs-tasks.amazonaws.com",
                "ecr.amazonaws.com"
            ]
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

resource "aws_iam_policy" "ecs_task_policy" {
  name   = "ecs-task-logging-policy"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action = [
          "ecr:*"
        ],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "arn:aws:logs:eu-central-1:057655471049:log-group:/ecs/cloudwatch-hello:*"
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "attach" {
  name       = "hello-attach"
  roles      = [aws_iam_role.ec2-stuff-role.name]
  policy_arn = aws_iam_policy.ecs_task_policy.arn
}

resource "aws_iam_policy" "ecs_logging_policy" {
  name   = "ecs_logging_policy"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "arn:aws:logs:eu-central-1:057655471049:log-group:/ecs/my-log-group:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_logging_policy" {
  role       = aws_iam_role.ec2-stuff-role.name
  policy_arn = aws_iam_policy.ecs_logging_policy.arn
}

resource "aws_iam_policy" "ecr_pull_policy" {
  name   = "ecr_pull_policy"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_pull_attachment" {
  role       = aws_iam_role.ec2-stuff-role.name
  policy_arn = aws_iam_policy.ecr_pull_policy.arn
}
###############

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true  # Ensure this is true
  enable_dns_hostnames = true # Ensure this is true
}

resource "aws_subnet" "main" {
  count      = 2
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.${count.index}.0/24"
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "main" {
  count          = 2
  subnet_id      = aws_subnet.main[count.index].id
  route_table_id = aws_route_table.main.id
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# Define the security group
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.main.id


  # Allow inbound traffic for internal communication
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Allow inbound HTTP traffic only from your IP address
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["${local.public_ip}/32"]
  }

  # Allow inbound traffic for the web service (port 4000)
  ingress {
    from_port   = 4000
    to_port     = 4000
    protocol    = "tcp"
    cidr_blocks = ["${local.public_ip}/32"]
  }

  # Allow outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web_sg"
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "hello_world_cluster"
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ec2-stuff-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_service_discovery_private_dns_namespace" "my_namespace" {
  name        = "my-service-discovery"
  vpc         = aws_vpc.main.id
  description = "Private DNS namespace for my ECS services"
}

resource "aws_service_discovery_service" "db" {
  name         = "db-service"
  namespace_id = aws_service_discovery_private_dns_namespace.my_namespace.id
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.my_namespace.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 60
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

# Task Definitions
resource "aws_ecs_task_definition" "db" {
  family                = "db"
  container_definitions = jsonencode([
    {
      name          = "db"
      image         = "public.ecr.aws/docker/library/postgres:14-alpine"
      port_mappings = [
        {
          containerPort = 5432
          hostPort      = 5432
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          awslogs-group         = aws_cloudwatch_log_group.cloudwatch-hello.name
          awslogs-region        = "eu-central-1"
          awslogs-stream-prefix = "app/db"
        }
      }
      environment = [
        {
          name  = "POSTGRES_USER"
          value = "postgres"
        },
        {
          name  = "POSTGRES_PASSWORD"
          value = "example"
        },
        {
          name  = "POSTGRES_DB"
          value = "puppamilafava"
        }
      ]
    }
  ])
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "1024"
  network_mode             = "awsvpc"
  task_role_arn            = "${aws_iam_role.ec2-stuff-role.arn}"
  execution_role_arn       = "${aws_iam_role.ec2-stuff-role.arn}"
}

resource "aws_ecs_task_definition" "adminer" {
  family                = "adminer"
  container_definitions = jsonencode([
    {
      name          = "adminer"
      image         = "public.ecr.aws/docker/library/adminer:latest"
      port_mappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          awslogs-group         = aws_cloudwatch_log_group.cloudwatch-hello.name
          awslogs-region        = "eu-central-1"
          awslogs-stream-prefix = "app/adminer"
        }
      }
      environment = [
        {
          name  = "ADMINER_DEFAULT_SERVER"
          value = "db-service.my-service-discovery"
        }
      ]
    }
  ])
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "1024"
  network_mode             = "awsvpc"
  task_role_arn            = "${aws_iam_role.ec2-stuff-role.arn}"
  execution_role_arn       = "${aws_iam_role.ec2-stuff-role.arn}"
}

resource "aws_cloudwatch_log_group" "cloudwatch-hello" {
  name = "/ecs/cloudwatch-hello"

  tags = {
    Environment = "production"
    Application = "hello"
  }
}

resource "aws_ecs_task_definition" "web" {
  family                = "web"
  container_definitions = jsonencode([
    {
      name          = "web"
      image         = "057655471049.dkr.ecr.eu-central-1.amazonaws.com/hello_world:1.0"
      port_mappings = [
        {
          containerPort = 4000
          hostPort      = 4000
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          awslogs-group         = aws_cloudwatch_log_group.cloudwatch-hello.name
          awslogs-region        = "eu-central-1"
          awslogs-stream-prefix = "app/web"
        }
      }
      environment = [
        {
          name  = "SECRET_KEY_BASE"
          value = "t46dvBqYRyMgmI+i6lKJvRfZ+nDrgCWJvnaAbaNj1J34PCgRYLP+pABfz28EjWDU"
        },
        {
          name  = "DATABASE_URL"
          value = "ecto://postgres:example@db-service.my-service-discovery:5432/puppamilafava"
        },
        {
          name  = "DB_HOST"
          value = "db-service.my-service-discovery"
        },
        {
          name = "PHX_SERVER"
          value = "enabled"
        }
      ]
    }
  ])
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "1024"
  network_mode             = "awsvpc"
  task_role_arn            = "${aws_iam_role.ec2-stuff-role.arn}"
  execution_role_arn       = "${aws_iam_role.ec2-stuff-role.arn}"
}

# ECS Services
resource "aws_ecs_service" "db" {
  name            = "db-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.db.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.main[*].id
    assign_public_ip = true
    security_groups  = [aws_security_group.web_sg.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.db.arn
  }
}

resource "aws_ecs_service" "adminer" {
  name            = "adminer-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.adminer.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  depends_on      = [aws_ecs_service.db]

  network_configuration {
    subnets          = aws_subnet.main[*].id
    assign_public_ip = true     # Provide the containers with public IPs
    security_groups  = [aws_security_group.web_sg.id]
  }

}

resource "aws_ecs_service" "web" {
  name                   = "web-service"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.web.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  depends_on             = [aws_ecs_service.db]
  enable_execute_command = true
  force_new_deployment = true

  network_configuration {
    subnets          = aws_subnet.main[*].id
    assign_public_ip = true     # Provide the containers with public IPs
    security_groups  = [aws_security_group.web_sg.id]
  }

}
