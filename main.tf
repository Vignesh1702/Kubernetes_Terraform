provider "aws" {
  region = var.region
  access_key = "AKIAVT7LDUTIKR4NJUWY"
  secret_key = "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"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "My-VPC" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "Main-IGW" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone	  = "ap-south-1a"
  map_public_ip_on_launch = true
  tags = { Name = "Main-Subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "Main-RT" }
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "k8s_sg" {
  name        = "k8s-sg"
  description = "Allow all traffic for cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow all TCP"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"         # -1 = all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "Kubernetes Security Group" }
}

# Generate an RSA key pair
resource "tls_private_key" "kube_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS key pair from the public key
resource "aws_key_pair" "kube_keypair" {
  key_name   = "k8s-key"
  public_key = tls_private_key.kube_key.public_key_openssh
}

# Save the private key to your local machine (downloads automatically)
resource "local_file" "kube_private_key" {
  content              = tls_private_key.kube_key.private_key_pem
  filename             = "${path.module}/k8s-key.pem"
  file_permission      = "0400"
  directory_permission = "0700"
}




resource "aws_instance" "master" {
  ami                         = "ami-0f918f7e67a3323f0" # Ubuntu 24.04 in ap-south-1
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.k8s_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.kube_keypair.key_name
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "Kube-Master"
  }

  provisioner "file" {
    source = "user_data/master.sh" 
    destination = "/tmp/master.sh"
      connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.kube_key.private_key_pem
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo hostnamectl set-hostname Kube-Master",
      "sudo apt update",
      "chmod +x /tmp/master.sh",
      "sudo /tmp/master.sh"
    ]
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.kube_key.private_key_pem
      host        = self.public_ip
    }
  }
}

resource "null_resource" "get_join_command" {
  depends_on = [aws_instance.master]

  provisioner "remote-exec" {
    inline = [
      "kubeadm token create --print-join-command > /tmp/join.sh",
      "chmod +x /tmp/join.sh"
    ]
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.kube_key.private_key_pem
      host        = aws_instance.master.public_ip
    }
  }

  provisioner "local-exec" {
    command = <<EOT
      ssh -o StrictHostKeyChecking=no -i ${path.module}/k8s-key.pem ubuntu@${aws_instance.master.public_ip} 'cat /tmp/join.sh' > join_command.sh
    EOT
  }
}

resource "aws_instance" "workers" {
  count                      = 3
  ami                        = "ami-0f918f7e67a3323f0"
  instance_type              = var.instance_type
  subnet_id                  = aws_subnet.public.id
  vpc_security_group_ids     = [aws_security_group.k8s_sg.id]
  associate_public_ip_address = true
  key_name                   = aws_key_pair.kube_keypair.key_name
  root_block_device {
    volume_size = 15
    volume_type = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "Kube-Worker-${count.index + 1}"
  }

  # Ensure this runs after join command is generated
  depends_on = [null_resource.get_join_command]

  provisioner "file" {
    source      = "user_data/worker.sh"
    destination = "/tmp/worker.sh"
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.kube_key.private_key_pem
      host        = self.public_ip
    }
  }

  provisioner "file" {
    source      = "join_command.sh"
    destination = "/tmp/join.sh"
      connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.kube_key.private_key_pem
      host        = self.public_ip
    }  
  }

  provisioner "remote-exec" {
    inline = [
      "sudo hostnamectl set-hostname Kube-Worker-${count.index + 1}",
      "sudo apt update",
      "chmod +x /tmp/worker.sh",
      "sudo /tmp/worker.sh",
      "chmod +x /tmp/join.sh",
      "sudo /tmp/join.sh"
    ]
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.kube_key.private_key_pem
      host        = self.public_ip
    }
  }
}
