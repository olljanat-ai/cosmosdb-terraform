variable "name" {
  description = "Name of the Cosmos DB account. Must be globally unique, 3-44 characters, lowercase letters, numbers and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$", var.name))
    error_message = "`name` must be 3-44 characters of lowercase letters, numbers and hyphens, and may not start or end with a hyphen."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group the Cosmos DB account is created in."
  type        = string
}

variable "location" {
  description = "Azure region of the write (primary) region of the account."
  type        = string
}

variable "databases" {
  description = <<-EOT
    MongoDB databases to create in the account.

    * `name`           - Database name.
    * `throughput`     - Provisioned throughput in RU/s. Conflicts with `max_throughput`. Leave both unset to share the account throughput.
    * `max_throughput` - Maximum autoscale throughput in RU/s. Conflicts with `throughput`.
    * `username`       - Username of the database owner. Defaults to the database name.
    * `password`       - Password of the database owner. A strong random password is generated when unset.
    * `role_names`     - Mongo roles granted to the user on this database only. Defaults to `dbOwner`, which is full ownership of that single database.
  EOT

  type = list(object({
    name           = string
    throughput     = optional(number)
    max_throughput = optional(number)
    username       = optional(string)
    password       = optional(string)
    role_names     = optional(list(string), ["dbOwner"])
  }))
  default = []

  validation {
    condition     = length(distinct([for db in var.databases : db.name])) == length(var.databases)
    error_message = "Every entry in `databases` must have a unique `name`."
  }

  validation {
    condition     = alltrue([for db in var.databases : db.throughput == null || db.max_throughput == null])
    error_message = "`throughput` and `max_throughput` are mutually exclusive, set at most one of them per database."
  }

  validation {
    condition     = alltrue([for db in var.databases : length(db.role_names) > 0])
    error_message = "`role_names` must contain at least one Mongo role."
  }
}

variable "create_database_users" {
  description = "Create a dedicated Mongo user (username + password) per database. Set to false when access is granted through Microsoft Entra ID identities only."
  type        = bool
  default     = true
}

variable "entra_id_access" {
  description = <<-EOT
    Microsoft Entra ID principals that are granted access to the account without a username and password
    of their own. Each entry creates an Azure RBAC role assignment scoped to the Cosmos DB account, which
    lets the principal read the account connection strings with its own Entra ID token.

    * `principal_id`         - Object ID of the managed identity, service principal, group or user.
    * `role_definition_name` - Azure built-in role to assign. Defaults to `Cosmos DB Account Reader Role`,
                               which grants read-only keys. Use `DocumentDB Account Contributor` when the
                               principal also needs to write data.
    * `principal_type`       - `User`, `Group` or `ServicePrincipal`. Set it for freshly created identities
                               to avoid replication errors during apply.
  EOT

  type = list(object({
    principal_id         = string
    role_definition_name = optional(string, "Cosmos DB Account Reader Role")
    principal_type       = optional(string)
  }))
  default = []

  validation {
    condition = length(distinct([
      for a in var.entra_id_access : "${a.principal_id}|${a.role_definition_name}"
    ])) == length(var.entra_id_access)
    error_message = "Every entry in `entra_id_access` must have a unique combination of `principal_id` and `role_definition_name`."
  }
}

variable "mongo_rbac_enabled" {
  description = "Enable the `EnableMongoRoleBasedAccessControl` capability. Required for per-database users."
  type        = bool
  default     = true
}

variable "mongo_server_version" {
  description = "MongoDB server version exposed by the account."
  type        = string
  default     = "7.0"
}

variable "additional_capabilities" {
  description = "Extra Cosmos DB capabilities to enable, for example `EnableMongoRetryableWrites`. `EnableMongo` is always enabled."
  type        = list(string)
  default     = []
}

variable "consistency_level" {
  description = "Consistency level of the account. One of `BoundedStaleness`, `ConsistentPrefix`, `Eventual`, `Session` or `Strong`."
  type        = string
  default     = "Session"

  validation {
    condition     = contains(["BoundedStaleness", "ConsistentPrefix", "Eventual", "Session", "Strong"], var.consistency_level)
    error_message = "`consistency_level` must be one of BoundedStaleness, ConsistentPrefix, Eventual, Session or Strong."
  }
}

variable "max_interval_in_seconds" {
  description = "Staleness window in seconds. Only valid when `consistency_level` is `BoundedStaleness`."
  type        = number
  default     = null
}

variable "max_staleness_prefix" {
  description = "Number of stale requests tolerated. Only valid when `consistency_level` is `BoundedStaleness`."
  type        = number
  default     = null
}

variable "secondary_locations" {
  description = "Additional Azure regions the data is replicated to, in failover priority order."
  type        = list(string)
  default     = []
}

variable "zone_redundant" {
  description = "Enable zone redundancy in every region of the account."
  type        = bool
  default     = false
}

variable "automatic_failover_enabled" {
  description = "Enable automatic failover. Defaults to true when `secondary_locations` is not empty."
  type        = bool
  default     = null
}

variable "public_network_access_enabled" {
  description = "Allow access to the account from public networks."
  type        = bool
  default     = true
}

variable "ip_range_filter" {
  description = "IP addresses or CIDR ranges allowed to reach the account. An empty list allows every client IP."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the Cosmos DB account."
  type        = map(string)
  default     = {}
}
