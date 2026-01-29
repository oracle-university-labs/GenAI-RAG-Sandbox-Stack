# GenAI RAG Stack (OCI Resource Manager)

A one-click **OCI Resource Manager** (ORM) stack that provisions a minimal environment for Gen-AI/RAG experiments:
- VCN/subnet + routing + security (as defined in the stack)
- Compute instance (flex) with cloud-init bootstrap
- IAM/Dynamic Group/Policies (if enabled)
- **Region-agnostic Oracle Linux 8 image auto-discovery** (no hard-coded OCIDs).  
  You can still override with `image_ocid` if you must pin a specific image.

> ✅ This version auto-selects the latest Oracle Linux 8 image in the region where you deploy the stack, filtered by `instance_shape` to avoid x86/ARM mismatches.

---

## Deploy with One Click

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ou-developers/GenAI-RAG-Sandbox-Stack/archive/refs/heads/main.zip)

### Alternative: Upload Manually
1. Download the ZIP release asset.
2. In OCI Console → **Developer Services → Resource Manager → Stacks → Create Stack**.
3. Choose **Upload Zip File** and select the ZIP.
4. Configure variables → **Plan** → **Apply**.

---

## Prerequisites

- OCI tenancy + permission to create Resource Manager stacks and target resources (VCN, instance, policies).
- SSH public key (if the instance expects it) ready to paste.
- Your **Tenancy OCID**, **Home Region**, and **Deployment Region**.
- (Optional) A specific **image OCID** if you need to lock to a given OS image build.

---

## Inputs (common variables)

> The exact list is in `variables.tf`; here are the typical ones you’ll see:

- `tenancy_ocid` *(string, required)* – Tenancy OCID.
- `home_region` *(string, required)* – Home region (e.g., `ap-hyderabad-1`).
- `region` *(string, required)* – Deployment region (e.g., `ap-mumbai-1`).  
  *If omitted in provider, ORM’s selected region is used.*
- `create_compartment` *(bool, default: true)* – Create a project compartment or use an existing one.
- `project_compartment_ocid` *(string, optional)* – If not creating a compartment, provide one.
- `project_compartment_name` *(string, optional)* – Name when creating a compartment.
- `instance_shape` *(string, required)* – e.g., `VM.Standard.E5.Flex` (the stack sets OCPUs/memory separately).
- `instance_ocpus` *(number, required for flex shapes)*.
- `instance_memory_gbs` *(number, required for flex shapes)*.
- `ssh_public_key` *(string, required)* – Paste your `~/.ssh/id_rsa.pub` (or equivalent).
- `open_tcp_ports_csv` *(string, default provided)* – e.g., `22,8888,8501,1521`.
- `create_policies` *(bool, default: true)* – Create Dynamic Group + Policies for service access.
- `image_ocid` *(string, optional)* – **Override**: use this instead of auto-discovered OL8.

---

## How Region-Agnostic Image Selection Works

- The stack uses `data "oci_core_images"` with:
  - `operating_system = "Oracle Linux"`, `operating_system_version = "8"`
  - `shape = var.instance_shape` (ensures correct arch/virt type)
  - `sort_by = TIMECREATED`, `sort_order = DESC` (picks newest)
- It sets:
  - `local.rg_effective_image_ocid = var.image_ocid != "" ? var.image_ocid : discovered_ol8_image_id`
- The instance launches from `local.rg_effective_image_ocid`.

This eliminates per-region OCID maps and “invalid parameter” errors when switching regions.

---

## Outputs

Open the **Outputs** tab after Apply. Typical values include:
- Instance OCID / Public IP / Private IP
- Subnet / VCN identifiers
- (If enabled) IAM/DG/Policy names or OCIDs

---

## Post-Deploy: Verify Setup

SSH into the instance and run:

```bash
# Did cloud-init finish?
sudo cloud-init status --wait && sudo cloud-init status --long

# Any failed services?
systemctl --failed

# Example package check (customize to your stack):
rpm -q httpd git unzip python3 python3-pip
```

**Background processes (e.g., Jupyter):**
- quick: `nohup bash start_jupyter.sh > jupyter.out 2>&1 & disown`
- robust: create a user `systemd` service

---

## Clean Up

To avoid charges:
1. In ORM → your stack → **Jobs**, run **Destroy**.
2. Delete the stack (and any manual leftovers if you created resources outside the stack).

---

## Changelog

- **v2 (region-agnostic-fix1)**  
  - Auto-discover latest **Oracle Linux 8** image in the deploy region  
  - `instance_shape`-aware image filtering  
  - Optional `image_ocid` override  
  - Fixed ternary & trimspace issue in image lookup

---

## Contributing

This project welcomes contributions from the community. Before submitting a pull request, please [review our contribution guide](./CONTRIBUTING.md)

---

## Security

Please consult the [security guide](./SECURITY.md) for our responsible security vulnerability disclosure process

---

## License

MIT (or your preferred license). Add a `LICENSE` file if needed.
