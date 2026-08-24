# =============================================================================
# Modulo: network
# VPC de tres capas -> edge (publica) / app (privada) / data (privada aislada).
# Reproduce la separacion DMZ <-> nucleo privado del diseno original.
# =============================================================================

locals {
  # La region se deduce de la primera AZ ("us-east-1a" -> "us-east-1").
  region = substr(var.azs[0], 0, length(var.azs[0]) - 1)

  # /16 partido en /24: edge 0-1, app 10-11, data 20-21
  edge_cidrs = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  app_cidrs  = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  data_cidrs = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, 20 + i)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

# ── Subredes ────────────────────────────────────────────────────────────────

resource "aws_subnet" "edge" {
  count = length(var.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.edge_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-edge-${var.azs[count.index]}"
    Tier = "edge"
  })
}

resource "aws_subnet" "app" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.app_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-app-${var.azs[count.index]}"
    Tier = "app"
  })
}

resource "aws_subnet" "data" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-data-${var.azs[count.index]}"
    Tier = "data"
  })
}

# ── Salida a internet ───────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.edge[0].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.this]
}

# ── Enrutamiento ────────────────────────────────────────────────────────────

resource "aws_route_table" "edge" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-edge" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-private" })
}

# La capa de datos no sale a internet: tabla de rutas sin default route.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-data" })
}

resource "aws_route_table_association" "edge" {
  count = length(var.azs)

  subnet_id      = aws_subnet.edge[count.index].id
  route_table_id = aws_route_table.edge.id
}

resource "aws_route_table_association" "app" {
  count = length(var.azs)

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "data" {
  count = length(var.azs)

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}
