provider "aws" {
  region = "ap-southeast-2"
}

# Create VPC
resource "aws_vpc" "crescendo_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Create Public Subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.crescendo_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-southeast-2a"
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.crescendo_vpc.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-southeast-2b"
}

# Create Private Subnets
resource "aws_subnet" "private_subnet_1" {
  vpc_id           = aws_vpc.crescendo_vpc.id
  cidr_block       = "10.0.3.0/24"
  availability_zone = "ap-southeast-2a"
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id           = aws_vpc.crescendo_vpc.id
  cidr_block       = "10.0.4.0/24"
  availability_zone = "ap-southeast-2b"
}

# Create Internet Gateway
resource "aws_internet_gateway" "crescendo_igw" {
  vpc_id = aws_vpc.crescendo_vpc.id
}

# Create Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
}

# Create NAT Gateway
resource "aws_nat_gateway" "crescendo_nat" {
  subnet_id     = aws_subnet.public_subnet_1.id
  allocation_id = aws_eip.nat.id
}

# Create Route Table for Public Subnets
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.crescendo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.crescendo_igw.id
  }
}

# Associate Public Subnets with Public Route Table
resource "aws_route_table_association" "public_assoc_1" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_assoc_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# Create Route Table for Private Subnets
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.crescendo_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.crescendo_nat.id
  }
}

# Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_assoc_1" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_assoc_2" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private_rt.id
}

# Create EC2 instance with Nginx and Tomcat
resource "aws_instance" "crescendo_demo" {
  ami                    = "ami-0013d898808600c4a"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public_subnet_1.id
  vpc_security_group_ids = [aws_security_group.crescendo_sg.id]
  key_name               = "cresendo"

  tags = { Name = "Crescendo Demo" }

user_data = <<-EOF
              #!/bin/bash
              # Install NGINX
                sudo yum update -y
                sudo yum install -y nginx
                sudo systemctl start nginx
                sudo systemctl enable nginx

              # Download and Setup Tomcat
                sudo yum install -y java-17-amazon-corretto
                cd /opt
                sudo curl -O https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.39/bin/apache-tomcat-10.1.39.tar.gz
                sudo tar -xvzf apache-tomcat-10.1.39.tar.gz
                mv apache-tomcat-10.1.39 tomcat
                sudo chmod +x tomcat/bin/*.sh
                cd /opt/tomcat/bin
                sudo ./startup.sh
EOF
}

# Create Security Group for EC2
resource "aws_security_group" "crescendo_sg" {
  vpc_id = aws_vpc.crescendo_vpc.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
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

# Create Application Load Balancer
resource "aws_lb" "crescendo_alb" {
  name               = "crescendo-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.crescendo_sg.id]
  subnets           = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
}

# Create Target Group for ALB
resource "aws_lb_target_group" "crescendo_tg" {
  name     = "crescendo-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.crescendo_vpc.id
}

# Attach EC2 instance to Target Group
resource "aws_lb_target_group_attachment" "crescendo_attachment" {
  target_group_arn = aws_lb_target_group.crescendo_tg.arn
  target_id        = aws_instance.crescendo_demo.id
  port            = 80
}

# Create ALB Listener
resource "aws_lb_listener" "crescendo_listener" {
  load_balancer_arn = aws_lb.crescendo_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.crescendo_tg.arn
  }
}

# Create CloudFront Distribution with ALB as Origin
resource "aws_cloudfront_distribution" "crescendo_cf" {
  origin {
    domain_name = aws_lb.crescendo_alb.dns_name
    origin_id   = "crescendo-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    viewer_protocol_policy = "redirect-to-https"
    target_origin_id       = "crescendo-alb"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    
    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }
  }

  ordered_cache_behavior {
    path_pattern          = "/tomcat/*"
    viewer_protocol_policy = "redirect-to-https"
    target_origin_id       = "crescendo-alb"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }
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
