# Nomad reference deployment of the inventory stack (added 2026-08-17;
# UNVALIDATED by decision — no Nomad cluster is available yet; double-checked
# against deploy/docker-compose.yml, which remains the executable reference).
#
# Topology translation: compose gives the three bus members static IPs on an
# internal network; Nomad instead runs EVERY task in ONE group, sharing one
# bridge network namespace — the same localhost-cluster shape as the
# two-process dev setup in deploy/DEPLOYMENT.md, with distinct JGroups ports
# (7800/7801/7802) and bus-transport ports (15701/15702/15703) per member.
# Consequence: one allocation, one node. Spreading members across nodes needs
# real service discovery for TCPPING (or JDBC_PING) — out of scope until a
# multi-node Nomad target exists.
#
# SECURITY invariant preserved: only 8081 (API), 8082 (web UI), and 8083
# (exporter) are published; JGroups 7800-7802 and bus 15701-15703 stay inside
# the allocation's network namespace. Bus membership is access.
#
# Images are the released GHCR images (private): the client node needs docker
# credentials for ghcr.io (docker login on the node, or add an `auth` block
# to each task). Run:
#
#   nomad job run -var version=<X.Y.Z> deploy/nomad/inventory.nomad.hcl
#
# The pgdata host volume must exist on the client first:
#   client { host_volume "inventory-pgdata" { path = "/opt/inventory/pgdata" } }

variable "version" {
  type        = string
  default     = "latest"
  description = "Released image tag (PLAN.md Phase 14): vX.Y.Z without the v."
}

variable "ghcr_owner" {
  type    = string
  default = "mykelalvis"
}

variable "postgres_password" {
  type    = string
  default = "inventory" # change outside dev
}

variable "bus_token" {
  type    = string
  default = "dev-bus-token" # change outside dev; same value on every member
}

variable "admin_email" {
  type    = string
  default = "admin@example.com"
}

variable "admin_password" {
  type    = string
  default = "change-me"
}

variable "qr_base_url" {
  type        = string
  default     = "http://localhost:8082"
  description = "Public base URL the printed QR deep links carry."
}

job "inventory" {
  datacenters = ["dc1"]
  type        = "service"

  group "inventory" {
    count = 1

    network {
      mode = "bridge"
      port "web_api" {
        static = 8081
        to     = 8081
      }
      port "web_app" {
        static = 8082
        to     = 8082
      }
      port "exporter" {
        static = 8083
        to     = 8083
      }
    }

    volume "pgdata" {
      type      = "host"
      source    = "inventory-pgdata"
      read_only = false
    }

    # Postgres runs for the life of the allocation, started before the main
    # tasks (prestart + sidecar).
    task "postgres" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image = "postgres:17-alpine"
      }

      env {
        POSTGRES_DB       = "inventory"
        POSTGRES_USER     = "inventory"
        POSTGRES_PASSWORD = var.postgres_password
      }

      volume_mount {
        volume      = "pgdata"
        destination = "/var/lib/postgresql/data"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }

    # Liquibase runs to completion before the main tasks start (prestart,
    # NOT sidecar). It races postgres's first boot, so failures retry until
    # the database answers — the compose depends_on translated to a restart
    # policy. Changelogs ship inside... nowhere on a Nomad client: mount the
    # inventory-impl-pg resources from a checkout on the node, exactly like the
    # compose bind mount (set the path for your node below).
    task "migrate" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      restart {
        attempts = 10
        delay    = "5s"
        interval = "5m"
        mode     = "delay"
      }

      config {
        image = "liquibase/liquibase:4.29"
        args = [
          "--url=jdbc:postgresql://127.0.0.1:5432/inventory",
          "--username=inventory",
          "--password=${var.postgres_password}",
          "--search-path=/liquibase/changelog",
          "--changelog-file=db/changelog-master.yaml",
          "update",
        ]
        # a checkout of inventory-impl-root on the client node (repo at the
        # tag being deployed — the same rule as the compose release deploy).
        # Docker-driver bind mounts require the client's plugin config:
        #   plugin "docker" { config { volumes { enabled = true } } }
        volumes = [
          "/opt/inventory/checkout/inventory-impl-root/inventory-impl-pg/src/main/resources:/liquibase/changelog:ro",
        ]
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }

    # The worker host: storage, transactions, audit, printing. No published
    # port — all its work arrives as bus envelopes.
    task "inventory-server" {
      driver = "docker"

      config {
        image = "ghcr.io/${var.ghcr_owner}/inventory-root/inventory-server:${var.version}"
      }

      env {
        # every task shares one netns and the web app owns 8082: the server's
        # internal-health HTTP moves to 8084 (the just dev-server convention)
        QUARKUS_HTTP_PORT                = "8084"
        INVENTORY_STORAGE                = "pg"
        QUARKUS_DATASOURCE_REACTIVE_URL  = "postgresql://127.0.0.1:5432/inventory"
        QUARKUS_DATASOURCE_USERNAME      = "inventory"
        QUARKUS_DATASOURCE_PASSWORD      = var.postgres_password
        QUARKUS_DEVSERVICES_ENABLED      = "false"
        INVENTORY_BUS_TOKEN              = var.bus_token
        INVENTORY_ADMIN_EMAIL            = var.admin_email
        INVENTORY_ADMIN_PASSWORD         = var.admin_password
        INVENTORY_EVENTS_BUS             = "clustered"
        INVENTORY_PRINTER                = "log" # point at hardware via job update
        QUARKUS_VERTX_CLUSTER_CLUSTERED  = "true"
        QUARKUS_VERTX_CLUSTER_HOST       = "127.0.0.1"
        QUARKUS_VERTX_CLUSTER_PORT       = "15701"
        JAVA_TOOL_OPTIONS                = "-Djgroups.bind.address=127.0.0.1 -Djgroups.tcp.port=7800 -Djgroups.tcpping.initial_hosts=127.0.0.1[7800],127.0.0.1[7801],127.0.0.1[7802] -Djava.net.preferIPv4Stack=true"
      }

      resources {
        cpu    = 1000
        memory = 768
      }
    }

    # The authenticated HTTP gateway (the only API entrypoint), :8081.
    task "inventory-web-api" {
      driver = "docker"

      config {
        image = "ghcr.io/${var.ghcr_owner}/inventory-root/inventory-web-api:${var.version}"
        ports = ["web_api"]
      }

      env {
        INVENTORY_BUS_WORKERS           = "remote"
        INVENTORY_BUS_TOKEN             = var.bus_token
        QUARKUS_DEVSERVICES_ENABLED     = "false"
        INVENTORY_QR_BASE_URL           = var.qr_base_url
        QUARKUS_VERTX_CLUSTER_CLUSTERED = "true"
        QUARKUS_VERTX_CLUSTER_HOST      = "127.0.0.1"
        QUARKUS_VERTX_CLUSTER_PORT      = "15702"
        JAVA_TOOL_OPTIONS               = "-Djgroups.bind.address=127.0.0.1 -Djgroups.tcp.port=7801 -Djgroups.tcpping.initial_hosts=127.0.0.1[7800],127.0.0.1[7801],127.0.0.1[7802] -Djava.net.preferIPv4Stack=true"
      }

      resources {
        cpu    = 1000
        memory = 768
      }
    }

    # Reference fact consumer, :8083. Poll-only is fully correct; cluster
    # membership is its latency upgrade.
    task "inventory-exporter" {
      driver = "docker"

      config {
        image = "ghcr.io/${var.ghcr_owner}/inventory-root/inventory-exporter:${var.version}"
        ports = ["exporter"]
      }

      env {
        QUARKUS_DATASOURCE_REACTIVE_URL = "postgresql://127.0.0.1:5432/inventory"
        QUARKUS_DATASOURCE_USERNAME     = "inventory"
        QUARKUS_DATASOURCE_PASSWORD     = var.postgres_password
        QUARKUS_DEVSERVICES_ENABLED     = "false"
        INVENTORY_EVENTS_BUS            = "clustered"
        QUARKUS_VERTX_CLUSTER_CLUSTERED = "true"
        QUARKUS_VERTX_CLUSTER_HOST      = "127.0.0.1"
        QUARKUS_VERTX_CLUSTER_PORT      = "15703"
        JAVA_TOOL_OPTIONS               = "-Djgroups.bind.address=127.0.0.1 -Djgroups.tcp.port=7802 -Djgroups.tcpping.initial_hosts=127.0.0.1[7800],127.0.0.1[7801],127.0.0.1[7802] -Djava.net.preferIPv4Stack=true"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }

    # The browser UI (native image), :8082 — talks only to the gateway.
    task "inventory-web-app" {
      driver = "docker"

      config {
        image = "ghcr.io/${var.ghcr_owner}/inventory-root/inventory-web-app:${var.version}"
        ports = ["web_app"]
      }

      env {
        INVENTORY_WEB_API_URL          = "http://127.0.0.1:8081"
        QUARKUS_PROFILE                = "prod"
        INVENTORY_WEBAPP_SESSION_FILE  = "none"
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }
  }
}
