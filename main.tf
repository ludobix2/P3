module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "prd"
  }
}


resource "aws_security_group" "web_sg" {
  name        = "web_security_group"
  description = "Allow HTTP, HTTPS, and SSH traffic"
  vpc_id      = module.vpc.vpc_id

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
    from_port   = 22
    to_port     = 22
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


resource "random_id" "bucket" {
  byte_length = 8
}

resource "aws_s3_bucket" "mybucket" {
  bucket = "mybucket-${random_id.bucket.hex}"

  tags = {
    Name = "mybucket-${random_id.bucket.hex}"
  }
}

resource "aws_s3_object" "index_php" {
  bucket = aws_s3_bucket.mybucket.id
  key    = "index.php"
  source = "index.php"
  content_type = "text/html"
}


resource "aws_instance" "web" {
  count         = 3
  ami           = "ami-00beae93a2d981137" 
  instance_type = "t2.micro"
  key_name      = "vockey"

  subnet_id = element(module.vpc.public_subnets, count.index)

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    yum install -y httpd php amazon-efs-utils aws-cli
    systemctl start httpd
    systemctl enable httpd
    mkdir -p /var/www/html
    mount -t efs -o tls ${aws_efs_file_system.efs.id}:/ /var/www/html
    echo "${aws_efs_file_system.efs.id}:/ /var/www/html efs defaults,_netdev 0 0" >> /etc/fstab
    aws s3 cp s3://${aws_s3_bucket.mybucket.id}/index.php /var/www/html/index.php
  EOF

  tags = {
    Name = "web_instance_${count.index}"
  }
}


resource "aws_efs_file_system" "efs" {
  creation_token = "example-efs"
}

resource "aws_efs_mount_target" "efs_mount" {
  count          = 3
  file_system_id = aws_efs_file_system.efs.id
  subnet_id      = element(module.vpc.private_subnets, count.index)
  security_groups = [aws_security_group.web_sg.id]
}

resource "aws_security_group_rule" "efs_ingress" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  security_group_id        = aws_security_group.web_sg.id
  source_security_group_id = aws_security_group.web_sg.id
}


resource "aws_lb" "app_lb" {
  name               = "app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "app_tg_attachment" {
  count = 3
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}


