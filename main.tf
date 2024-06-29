provider "aws" {
  region = "us-east-1"
}


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
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH"
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

  depends_on = [module.vpc]
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


resource "aws_s3_bucket_public_access_block" "mybucket" {
  bucket = aws_s3_bucket.mybucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}


resource "time_sleep" "wait_10_seconds" {
  depends_on      = [aws_s3_bucket.mybucket]
  create_duration = "10s"
}


resource "aws_s3_bucket_policy" "mybucket" {
  bucket = aws_s3_bucket.mybucket.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::${aws_s3_bucket.mybucket.id}/*"
      ]
    }
  ]
}
EOF
  depends_on = [time_sleep.wait_10_seconds]
}


resource "aws_s3_object" "index_php" {
  bucket = aws_s3_bucket.mybucket.id
  key    = "index.php"
  source = "index.php"
  content_type = "text/html"
}


resource "aws_efs_file_system" "efs" {
  creation_token = "example-efs-${random_id.bucket.hex}"
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  depends_on = [aws_security_group.web_sg]
}


resource "aws_security_group" "efs_sg" {
  name_prefix = "efs_sg"
  description = "Allow NFS traffic from EC2 instances"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  depends_on = [aws_efs_file_system.efs]
}


resource "aws_efs_mount_target" "efs_mount" {
  count          = 3
  file_system_id = aws_efs_file_system.efs.id
  subnet_id      = element(module.vpc.private_subnets, count.index)
  security_groups = [aws_security_group.efs_sg.id]

  depends_on = [aws_efs_file_system.efs, aws_security_group.efs_sg]
}


resource "aws_instance" "web" {
  count         = 3
  ami           = "ami-08a0d1e16fc3f61ea" # Amazon Linux 2023 en us-east-1
  instance_type = "t2.micro"
  subnet_id     = element(module.vpc.public_subnets, count.index)
  availability_zone = element(module.vpc.azs, count.index)
  key_name      = "vockey"
  security_groups = [aws_security_group.web_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd php amazon-efs-utils
    mkdir -p /var/www/html
    echo "${aws_efs_file_system.efs.id}.efs.${data.aws_region.current.name}.amazonaws.com:/ /var/www/html efs defaults,_netdev 0 0" >> /etc/fstab
    mount -a
    sleep 60
    sudo aws s3 cp s3://${aws_s3_bucket.mybucket.bucket}/index.php /var/www/html/ --no-sign-request
    systemctl start httpd
    systemctl enable httpd
  EOF

  tags = {
    Name = "web_instance_${count.index}"
  }

  depends_on = [aws_security_group.web_sg, aws_efs_mount_target.efs_mount]
}


resource "aws_lb" "app_lb" {
  name               = "app-lb-${random_id.bucket.hex}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false

  tags = {
    Name = "my-lb"
  }

  depends_on = [aws_instance.web]
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg-${random_id.bucket.hex}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    interval            = 30
    path                = "/"
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }

  depends_on = [aws_lb.app_lb]
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }

  depends_on = [aws_lb_target_group.app_tg]
}

resource "aws_lb_target_group_attachment" "app_tg_attachment" {
  count            = 3
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = element(aws_instance.web.*.id, count.index)
  port             = 80

  depends_on = [aws_instance.web, aws_lb_target_group.app_tg]
}

data "aws_region" "current" {}


resource "null_resource" "print_lb_url" {
  provisioner "local-exec" {
    command = "echo 'La página web está disponible en http://${aws_lb.app_lb.dns_name}'"
  }

  depends_on = [aws_lb_listener.app_listener]
}
