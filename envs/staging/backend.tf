terraform {
  backend "s3" {
    bucket       = "epixdevo-storm-ready-tfstate"
    key          = "envs/staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
