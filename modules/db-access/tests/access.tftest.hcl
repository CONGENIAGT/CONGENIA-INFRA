mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { name = "congenia-prod-db-access" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { name = "congenia-prod-db-access" }
  }
  mock_resource "aws_instance" {
    defaults = { arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0" }
  }
  mock_resource "aws_ssm_document" {
    defaults = { arn = "arn:aws:ssm:us-east-1:123456789012:document/congenia-prod-db-access" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/congenia/db-access/congenia-prod-db-access-operator" }
  }
}

variables {
  connection = {
    version     = 1
    account_id  = "123456789012"
    region      = "us-east-1"
    name_prefix = "congenia"
    environment = "prod"
    vpc_id      = "vpc-0123456789abcdef0"
    subnet_id   = "subnet-0123456789abcdef0"
    data_sg_id  = "sg-0123456789abcdef0"
    db_host     = "test.us-east-1.rds.amazonaws.com"
    db_port     = 5432
    db_name     = "congenia"
  }
  tags                = { Project = "CONGENIA", Component = "db-access", Environment = "prod" }
  operator_role_names = ["existing-operator"]
}

run "private_tunnel_and_cleanup_contract" {
  command = apply
  assert {
    condition     = !aws_instance.relay.associate_public_ip_address && aws_instance.relay.metadata_options[0].http_tokens == "required"
    error_message = "El acceso debe ser privado y exigir IMDSv2."
  }
  assert {
    condition     = aws_instance.relay.root_block_device[0].encrypted && aws_instance.relay.root_block_device[0].delete_on_termination
    error_message = "El disco debe cifrarse y borrarse al eliminar la EC2."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres.from_port == 5432 && aws_vpc_security_group_ingress_rule.postgres.to_port == 5432 && aws_vpc_security_group_ingress_rule.postgres.security_group_id == var.connection.data_sg_id
    error_message = "El acceso de datos debe limitarse a PostgreSQL."
  }
  assert {
    condition     = jsondecode(aws_ssm_document.tunnel.content).properties.host == var.connection.db_host && jsondecode(aws_ssm_document.tunnel.content).properties.portNumber == "5432" && !contains(keys(jsondecode(aws_ssm_document.tunnel.content).parameters), "host")
    error_message = "El operador no puede cambiar el host de destino del tunel."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres.tags.Component == "db-access" && aws_vpc_security_group_ingress_rule.postgres.tags.Name == "congenia-prod-db-access"
    error_message = "La regla sobre data debe poder encontrarse y limpiarse por componente."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.operator["existing-operator"].policy_arn == aws_iam_policy.operator.arn
    error_message = "La asignacion al operador debe pertenecer a Terraform para retirarla durante destroy."
  }
}

run "keycloak_console_through_the_same_relay" {
  command = apply
  variables {
    connection = {
      version              = 1
      account_id           = "123456789012"
      region               = "us-east-1"
      name_prefix          = "congenia"
      environment          = "prod"
      vpc_id               = "vpc-0123456789abcdef0"
      subnet_id            = "subnet-0123456789abcdef0"
      data_sg_id           = "sg-0123456789abcdef0"
      db_host              = "test.us-east-1.rds.amazonaws.com"
      db_port              = 5432
      db_name              = "congenia"
      operator_sg_id       = "sg-0fedcba9876543210"
      keycloak_host        = "keycloak.congenia.internal"
      keycloak_port        = 8080
      keycloak_tunnel_port = 18080
    }
  }
  assert {
    condition     = contains(aws_instance.relay.vpc_security_group_ids, "sg-0fedcba9876543210")
    error_message = "El relay debe adjuntar el grupo de operador para llegar a Keycloak."
  }
  assert {
    condition     = jsondecode(aws_ssm_document.keycloak[0].content).properties.host == "keycloak.congenia.internal" && jsondecode(aws_ssm_document.keycloak[0].content).properties.portNumber == "8080"
    error_message = "El tunel de Keycloak debe tener destino fijo."
  }
  assert {
    condition     = jsondecode(aws_ssm_document.keycloak[0].content).parameters.localPortNumber.allowedPattern == "^18080$" && !contains(keys(jsondecode(aws_ssm_document.keycloak[0].content).parameters), "host")
    error_message = "El puerto local debe ser el que Keycloak anuncia y el host no es parametro."
  }
}

run "older_contract_has_no_keycloak_tunnel" {
  command = apply
  assert {
    condition     = length(aws_ssm_document.keycloak) == 0 && length(aws_instance.relay.vpc_security_group_ids) == 1
    error_message = "Sin destino de Keycloak en el contrato no se crea su tunel."
  }
}
