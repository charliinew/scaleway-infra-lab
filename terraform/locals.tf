resource "random_id" "suffix" {
  byte_length = 3 # 6 hex chars, e.g. "a1b2c3"
}

locals {
  suffix = random_id.suffix.hex
}
