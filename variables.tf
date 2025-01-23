variable "aws_region" {
  description = "AWS 리전"
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
}

variable "environment" {
  description = "배포 환경 (dev, staging, prod)"
  default     = "dev"
}
