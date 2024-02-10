variable "hosted_zone" {
  default = "abc.com"
  type    = string
}

variable "cluster_name" {
  default = "my-cluster"
  type    = string
}

variable "api_name" {
  default = "my-api"
  type    = string
}

variable "ecr_repo" {
  default = "ecr"
  type    = string
}

variable "api_up_text" {
  default = "up"
  type    = string
}

variable "api_text_override" {
  default = ""
  type = string
  description = "overrides the entire response, meaning no json if you dont want it"
}