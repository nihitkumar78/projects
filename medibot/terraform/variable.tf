variable "region" {
  default = "ap-south-1"
}

# No default on purpose — do NOT hardcode a real password here, and do
# NOT commit a .tfvars file containing one. Supply it at apply-time:
#   terraform apply -var="db_password=<your-own-password>"
# or via a gitignored terraform.tfvars file, or via the
# TF_VAR_db_password environment variable.
variable "db_password" {
  type      = string
  sensitive = true
}
