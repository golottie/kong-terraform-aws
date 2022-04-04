locals {
  enable_rds = var.enable_aurora ? false : true
}
