resource "aws_key_pair" "localstack" {
  key_name   = "${var.project_name}-key"
  public_key = file("${path.module}/localstack.pub")
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*"]
  }

  filter {
    name   = "architecture"
    values = [var.instance_architecture]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  web_ami = coalesce(var.web_ami_id, data.aws_ami.ubuntu.id)
}

resource "aws_instance" "web" {
  ami                         = local.web_ami
  instance_type               = var.web_instance_type
  subnet_id                   = aws_subnet.public[0].id
  key_name                    = aws_key_pair.localstack.key_name
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true

  user_data = base64encode(<<EOF
#!/bin/bash
echo "Web Server - ${var.project_name}" > /var/www/html/index.html
EOF
  )

  tags = {
    Name = "${var.project_name}-web-1"
    Tier = "web"
  }
}
