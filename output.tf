output "master_public_ip" {
  value = aws_instance.master.public_ip
}

output "worker_public_ips" {
  value = [for instance in aws_instance.workers : instance.public_ip]
}
