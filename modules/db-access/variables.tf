variable "connection" {
  description = "Contrato sin credenciales exportado por envs/aws."
  type = object({
    version     = number
    account_id  = string
    region      = string
    name_prefix = string
    environment = string
    vpc_id      = string
    subnet_id   = string
    data_sg_id  = string
    db_host     = string
    db_port     = number
    db_name     = string
  })
}

variable "tags" {
  type = map(string)
}

variable "operator_role_names" {
  type    = set(string)
  default = []
}

variable "operator_user_names" {
  type    = set(string)
  default = []
}
