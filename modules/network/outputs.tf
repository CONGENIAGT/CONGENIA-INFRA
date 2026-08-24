output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "edge_subnet_ids" {
  value = aws_subnet.edge[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "edge_sg_id" {
  value = aws_security_group.edge.id
}

output "app_sg_id" {
  value = aws_security_group.app.id
}

output "data_sg_id" {
  value = aws_security_group.data.id
}

output "private_route_table_ids" {
  value = [aws_route_table.private.id, aws_route_table.data.id]
}

output "nat_gateway_id" {
  value = var.enable_nat_gateway ? aws_nat_gateway.this[0].id : null
}
