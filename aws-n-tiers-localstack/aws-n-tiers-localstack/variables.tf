variable "project_name" {
  type    = string
  default = "lab-factory"
}

variable "aws_region" {
  type    = string
  default = "eu-west-3"
}

variable "vpc_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "db_username" {
  description = "Nom d'utilisateur applicatif stocké dans Secrets Manager"
  type        = string
  default     = "admin"
}

variable "web_ami_id" {
  description = "Override optionnel pour l'AMI de l'instance web. Si null, le data source aws_ami.ubuntu prend le relais. À renseigner pour LocalStack avec une AMI Docker-backed (ex: ami-df5de72bdb3b)"
  type        = string
  default     = null
}

variable "instance_architecture" {
  description = "Architecture CPU de l'instance EC2. 'x86_64' pour Intel/AMD (t3.*, m5.*, c5.*), 'arm64' pour Graviton ou Mac M-series (t4g.*, m6g.*, c6g.*). Doit être cohérent avec instance_type"
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.instance_architecture)
    error_message = "instance_architecture doit être 'x86_64' ou 'arm64'."
  }
}

variable "web_instance_type" {
  description = "Type d'instance EC2. Doit être cohérent avec instance_architecture (t3.micro pour x86_64, t4g.micro pour arm64)"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs autorisés pour SSH vers l'instance web. Par défaut ouvert (LocalStack en local). À restreindre impérativement sur un compte AWS réel (ex: ['ton.ip.publique/32'])"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}