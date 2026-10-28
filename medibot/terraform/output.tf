output "jenkins_public_ip" {
  value = aws_instance.jenkins.public_ip
}

output "sonarqube_public_ip" {
  value = aws_instance.sonarqube.public_ip
}

output "nexus_public_ip" {
  value = aws_instance.nexus.public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.endpoint
}

output "eks_cluster_name" {
  value = aws_eks_cluster.medibot.name
}
