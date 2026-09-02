variable "resource_group_name" {
  description = "Name of the resource group that holds the whole environment."
  type        = string
}

variable "location" {
  description = "Azure region of the environment and of the account's write region."
  type        = string
}

variable "account_name" {
  description = "Name of the Cosmos DB account. Becomes part of a public DNS name, so it must be globally unique. 3-44 characters of lowercase letters, numbers and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$", var.account_name))
    error_message = "`account_name` must be 3-44 characters of lowercase letters, numbers and hyphens, and may not start or end with a hyphen."
  }
}

variable "databases" {
  description = <<-DESCRIPTION
    The databases of the account, keyed by database name. Each one gets a managed identity of its own, and that identity is granted `Cosmos DB Built-in Data Contributor` on that database and nothing else.

    * `throughput`     - Provisioned throughput of the database in RU/s. Conflicts with `max_throughput`. Leave both unset for a database whose containers carry their own throughput.
    * `max_throughput` - Maximum autoscale throughput of the database in RU/s.
    * `identity`       - The identity created for this database.
      * `enabled`               - Create it. Defaults to true. Set to false for a database whose principals are all handed in below.
      * `name`                  - Name of the identity. Defaults to `id-<account>-<database>`.
      * `federated_credentials` - Trusts between the identity and an external OIDC issuer, keyed by credential name. This is what a Kubernetes service account or a pipeline uses to become this identity without a secret.
        * `issuer`   - OIDC issuer URL, for example the OIDC issuer of an AKS cluster.
        * `subject`  - Subject the issuer asserts, for example `system:serviceaccount:<namespace>:<service-account>`.
        * `audience` - Audiences accepted. Defaults to `["api://AzureADTokenExchange"]`.
    * `contributor_principal_ids` - Object IDs of further principals that read and write this database.
    * `reader_principal_ids`      - Object IDs of principals that only read this database.
    * `containers` - Containers of the database, keyed by container name.
      * `partition_key_paths`   - Partition key paths, for example `["/customerId"]`. Required.
      * `partition_key_version` - Partition key version, 2 for large partition keys. Defaults to 2.
      * `throughput`            - Provisioned throughput of the container in RU/s. Conflicts with `max_throughput`.
      * `max_throughput`        - Maximum autoscale throughput of the container in RU/s.
      * `default_ttl`           - Seconds after which an item expires, `-1` for a TTL that is on but not enforced by default.
      * `unique_key_paths`      - Unique keys of the container, each one a list of paths.
  DESCRIPTION

  type = map(object({
    throughput     = optional(number)
    max_throughput = optional(number)

    identity = optional(object({
      enabled = optional(bool, true)
      name    = optional(string)

      federated_credentials = optional(map(object({
        issuer   = string
        subject  = string
        audience = optional(list(string), ["api://AzureADTokenExchange"])
      })), {})
    }), {})

    contributor_principal_ids = optional(list(string), [])
    reader_principal_ids      = optional(list(string), [])

    containers = optional(map(object({
      partition_key_paths   = list(string)
      partition_key_version = optional(number, 2)
      throughput            = optional(number)
      max_throughput        = optional(number)
      default_ttl           = optional(number)
      unique_key_paths      = optional(list(list(string)), [])
    })), {})
  }))

  validation {
    condition     = length(var.databases) > 0
    error_message = "`databases` must contain at least one database. The account disables key based authentication only when it has a SQL database, and an account with no database and no keys is one nothing can use."
  }

  validation {
    condition = alltrue([
      for name in keys(var.databases) :
      length(name) <= 255 && !can(regex("[/\\\\#?]", name)) && trimspace(name) == name
    ])
    error_message = "A database name must be at most 255 characters and may not contain `/`, `\\`, `#`, `?` or leading and trailing whitespace."
  }

  validation {
    condition = alltrue([
      for database in values(var.databases) :
      database.throughput == null || database.max_throughput == null
    ])
    error_message = "`throughput` and `max_throughput` are mutually exclusive, set at most one of them per database."
  }

  validation {
    condition = alltrue(flatten([
      for database in values(var.databases) : [
        for container in values(database.containers) :
        container.throughput == null || container.max_throughput == null
      ]
    ]))
    error_message = "`throughput` and `max_throughput` are mutually exclusive, set at most one of them per container."
  }

  validation {
    condition = alltrue(flatten([
      for database in values(var.databases) : [
        for container in values(database.containers) :
        length(container.partition_key_paths) > 0 && alltrue([for path in container.partition_key_paths : startswith(path, "/")])
      ]
    ]))
    error_message = "Every container needs at least one `partition_key_paths` entry, and every path starts with `/`."
  }

  validation {
    condition = alltrue(flatten([
      for database in values(var.databases) : [
        for principal_id in concat(database.contributor_principal_ids, database.reader_principal_ids) :
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", principal_id))
      ]
    ]))
    error_message = "Every principal ID in `contributor_principal_ids` and `reader_principal_ids` must be the object ID of a principal, which is a GUID."
  }

  validation {
    condition = alltrue([
      for database in values(var.databases) :
      length(distinct(concat(database.contributor_principal_ids, database.reader_principal_ids))) == length(concat(database.contributor_principal_ids, database.reader_principal_ids))
    ])
    error_message = "A principal may appear once per database. Listing it as both a contributor and a reader of the same database is ambiguous."
  }
}

variable "account_contributor_principal_ids" {
  description = "Object IDs of principals granted `Cosmos DB Built-in Data Contributor` on the whole account, which is every database in it. Empty, because access stopping at one database is the point of this configuration. This is where a migration job that spans databases goes, if there is one."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for principal_id in var.account_contributor_principal_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", principal_id))])
    error_message = "Every entry in `account_contributor_principal_ids` must be the object ID of a principal, which is a GUID."
  }
}

variable "account_reader_principal_ids" {
  description = "Object IDs of principals granted `Cosmos DB Built-in Data Reader` on the whole account. This is where a support or reporting identity goes, one that reads every database but writes none."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for principal_id in var.account_reader_principal_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", principal_id))])
    error_message = "Every entry in `account_reader_principal_ids` must be the object ID of a principal, which is a GUID."
  }

  validation {
    condition     = length(setintersection(toset(var.account_reader_principal_ids), toset(var.account_contributor_principal_ids))) == 0
    error_message = "A principal may hold one account wide role, not both. Contributor already includes what reader grants."
  }
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
  description = "Staleness window in seconds. Only used when `consistency_level` is `BoundedStaleness`."
  type        = number
  default     = null
}

variable "max_staleness_prefix" {
  description = "Number of stale requests tolerated. Only used when `consistency_level` is `BoundedStaleness`."
  type        = number
  default     = null
}

variable "secondary_locations" {
  description = "Additional Azure regions the data is replicated to, in failover priority order."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.secondary_locations, var.location)
    error_message = "`secondary_locations` must not repeat `location`, which is already the write region."
  }
}

variable "zone_redundant" {
  description = "Enable zone redundancy in every region of the account. Only regions with availability zones accept it."
  type        = bool
  default     = false
}

variable "automatic_failover_enabled" {
  description = "Enable service managed failover. Defaults to true when `secondary_locations` is not empty."
  type        = bool
  default     = null
}

variable "public_network_access_enabled" {
  description = "Allow access to the account from public networks. Off, the account is reached over a private endpoint."
  type        = bool
  default     = false
}

variable "ip_range_filter" {
  description = "IP addresses or CIDR ranges allowed to reach the account. Only applied when `public_network_access_enabled` is true."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.ip_range_filter) == 0 || var.public_network_access_enabled
    error_message = "`ip_range_filter` only applies when `public_network_access_enabled` is true."
  }
}

variable "private_endpoint_subnet_id" {
  description = "Resource ID of the subnet the private endpoint of the account is created in. Leave unset to create no private endpoint, for example when one is created outside this configuration."
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = "Resource IDs of the private DNS zones the private endpoint registers in, normally one `privatelink.documents.azure.com` zone. Without a zone the endpoint gets no DNS record and the name of the account still resolves to its public address."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.private_dns_zone_ids) == 0 || var.private_endpoint_subnet_id != null
    error_message = "`private_dns_zone_ids` needs `private_endpoint_subnet_id`, the zones are attached to the private endpoint this configuration creates."
  }
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of a Log Analytics workspace that receives the diagnostic logs and metrics of the account. Leave unset to create no diagnostic setting."
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
