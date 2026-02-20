data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
  provider       = oci.home
}

data "oci_core_images" "ol9" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "dev" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.project_compartment_ocid
  display_name        = "GEN-AI-LABS"

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = "genaivm"
  }

  shape = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = local.rg_effective_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = filebase64("${path.module}/cloudinit.sh")
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false
  }

  launch_options { network_type = "PARAVIRTUALIZED" }
  instance_options { are_legacy_imds_endpoints_disabled = true }

  timeouts { create = "60m" }

  lifecycle {
    precondition {
      condition     = var.create_compartment || (trimspace(var.project_compartment_ocid) != "")
      error_message = "When create_compartment=false you must provide project_compartment_ocid."
    }
  }
}