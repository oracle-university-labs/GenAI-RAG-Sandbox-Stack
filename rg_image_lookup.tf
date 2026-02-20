variable "image_ocid" {
  description = "Optional override: if set, use this image OCID instead of auto-discovery."
  type        = string
  default     = ""
}

# Region-agnostic Oracle Linux 8 image discovery in the CURRENT region of the provider/ORM stack
data "oci_core_images" "rg_ol8_latest" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  # Use the selected shape to ensure architecture compatibility (x86 vs aarch64)
  shape = var.instance_shape

  # Keep only standard OL8 images (excludes minimal/specialized)
  filter {
    name   = "display_name"
    values = ["^Oracle-Linux-8.*$"]
    regex  = true
  }
}

locals {
  rg_discovered_image_ocid = length(data.oci_core_images.rg_ol8_latest.images) > 0 ? data.oci_core_images.rg_ol8_latest.images[0].id : ""
  rg_effective_image_ocid  = trimspace(var.image_ocid) != "" ? var.image_ocid : local.rg_discovered_image_ocid
}

# Fail fast if no image was found — prevents cryptic 400 CannotParseRequest from OCI API
resource "terraform_data" "image_validation" {
  lifecycle {
    precondition {
      condition     = local.rg_effective_image_ocid != ""
      error_message = "No Oracle Linux 8 image found for shape '${var.instance_shape}' in this region. Set image_ocid manually."
    }
  }
}
