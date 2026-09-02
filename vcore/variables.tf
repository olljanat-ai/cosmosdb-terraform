variable "resource_group_name" {
  description = "Name of the resource group that holds the whole environment."
  type        = string
}

variable "location" {
  description = "Azure region of the cluster."
  type        = string
}

variable "cluster_name" {
  description = "Name of the MongoDB vCore cluster. Becomes part of a public DNS name, so it must be globally unique. 3-40 characters of lowercase letters, numbers and single hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.cluster_name)) && length(var.cluster_name) >= 3 && length(var.cluster_name) <= 40
    error_message = "`cluster_name` must be 3-40 characters of lowercase letters and numbers, separated by single hyphens, and may not start or end with a hyphen."
  }
}

variable "entra_administrators" {
  description = <<-DESCRIPTION
    Microsoft Entra ID principals that may connect to the cluster, keyed by a name of your choosing. This is the whole access list: with native authentication off, a principal that is not here cannot reach the data at all.

    * `object_id`      - Object ID of the principal. For a managed identity this is the object ID of the identity, not its client ID, and not the ID of the resource it is attached to.
    * `principal_type` - `servicePrincipal` for a managed identity, an application or a service principal, `user` for a person. Defaults to `servicePrincipal`.

    Every principal is granted `root` on `admin`, which is the only role the cluster user API accepts today.
  DESCRIPTION

  type = map(object({
    object_id      = string
    principal_type = optional(string, "servicePrincipal")
  }))

  validation {
    condition     = length(var.entra_administrators) > 0
    error_message = "`entra_administrators` must contain at least one principal, otherwise nothing can reach the cluster: password authentication is off and Entra ID principals are the only credentials it accepts."
  }

  validation {
    condition = alltrue([
      for principal in values(var.entra_administrators) :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", principal.object_id))
    ])
    error_message = "Every `object_id` in `entra_administrators` must be a GUID."
  }

  validation {
    condition = alltrue([
      for principal in values(var.entra_administrators) :
      contains(["servicePrincipal", "user"], principal.principal_type)
    ])
    error_message = "Every `principal_type` in `entra_administrators` must be either `servicePrincipal` or `user`."
  }

  validation {
    condition     = length(distinct([for principal in values(var.entra_administrators) : lower(principal.object_id)])) == length(var.entra_administrators)
    error_message = "`entra_administrators` must not name the same `object_id` twice, one principal is one cluster user."
  }
}

variable "native_authentication_enabled" {
  description = "Also allow username and password authentication on the cluster. Off, which is what makes the generated administrator password unusable and Entra ID the only way in. See the \"Native authentication\" section of the README before turning it on."
  type        = bool
  default     = false
}

variable "compute_tier" {
  description = "Compute tier of the cluster, for example `M10`, `M30` or `M40`. Entra ID authentication is not offered on the free tier, so this has to be a paid tier."
  type        = string
  default     = "M30"
}

variable "storage_size_gb" {
  description = "Size of the data disk of every node, in GB."
  type        = number
  default     = 32
}

variable "storage_type" {
  description = "Storage type to provision, `PremiumSSD` or `PremiumSSDv2`. Leave unset for the service default. Create time only, changing it replaces the cluster."
  type        = string
  default     = null

  validation {
    condition     = var.storage_type == null || contains(["PremiumSSD", "PremiumSSDv2"], var.storage_type)
    error_message = "`storage_type` must be either `PremiumSSD` or `PremiumSSDv2`."
  }
}

variable "shard_count" {
  description = "Number of shards provisioned on the cluster."
  type        = number
  default     = 1
}

variable "server_version" {
  description = "MongoDB server version of the cluster."
  type        = string
  default     = "7.0"
}

variable "high_availability_mode" {
  description = "High availability of the cluster. `Disabled` is a single node, `SameZone` adds a standby in the same availability zone, `ZoneRedundantPreferred` puts the standby in another zone where the region has them. Anything but `Disabled` needs the `M30` tier or higher."
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "SameZone", "ZoneRedundantPreferred"], var.high_availability_mode)
    error_message = "`high_availability_mode` must be one of Disabled, SameZone or ZoneRedundantPreferred."
  }
}

variable "public_network_access_enabled" {
  description = "Allow access to the cluster from public networks. Off, the cluster is reached over a private endpoint."
  type        = bool
  default     = false
}

variable "firewall_rules" {
  description = "Public IP ranges allowed to reach the cluster. Only applied when `public_network_access_enabled` is true."

  type = list(object({
    name     = string
    start_ip = string
    end_ip   = string
  }))
  default = []

  validation {
    condition     = length(var.firewall_rules) == 0 || var.public_network_access_enabled
    error_message = "`firewall_rules` only apply when `public_network_access_enabled` is true. They are silently ignored otherwise, so this is an error rather than a surprise."
  }

  validation {
    condition     = length(distinct([for rule in var.firewall_rules : rule.name])) == length(var.firewall_rules)
    error_message = "Every rule in `firewall_rules` must have a unique `name`."
  }
}

variable "private_endpoint_subnet_id" {
  description = "Resource ID of the subnet the private endpoint of the cluster is created in. Leave unset to create no private endpoint, for example when one is created outside this configuration."
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = "Resource IDs of the private DNS zones the private endpoint registers in, normally one `privatelink.mongocluster.cosmos.azure.com` zone. Without a zone the endpoint gets no DNS record and the name of the cluster still resolves to its public address."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.private_dns_zone_ids) == 0 || var.private_endpoint_subnet_id != null
    error_message = "`private_dns_zone_ids` needs `private_endpoint_subnet_id`, the zones are attached to the private endpoint this configuration creates."
  }
}

variable "data_api_enabled" {
  description = "Enable the Mongo Data API, an HTTPS endpoint onto the same data. Off, it is a second data plane surface and this configuration does not need it."
  type        = bool
  default     = false
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of a Log Analytics workspace that receives the diagnostic logs and metrics of the cluster. Leave unset to create no diagnostic setting."
  type        = string
  default     = null
}

variable "enable_telemetry" {
  description = "Whether the Azure Verified Module underneath sends its deployment telemetry to Microsoft. See <https://aka.ms/avm/telemetryinfo>."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in the environment."
  type        = map(string)
  default     = {}
}
