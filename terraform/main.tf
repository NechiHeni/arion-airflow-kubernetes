terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.92.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">=2.11.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">=2.10.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}


provider "azurerm" {
  subscription_id = "79d70fcd-2018-4a86-bbf8-9c1f7d4e54c3"
  features {}
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.main.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.main.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  }
}
provider "github" {
  token = var.github_token
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.app_name}rg"
  location = var.location
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.app_name}aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${var.app_name}-aks"

  default_node_pool {
    name       = "default"
    node_count = 2
    vm_size    = "Standard_DS2_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  storage_profile {
    blob_driver_enabled = true
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }
}


resource "azurerm_storage_account" "airflow" {
  name                     = "${var.app_name}airflowsa"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "airflow_logs" {
  name                  = "airflow-logs"
  storage_account_name  = azurerm_storage_account.airflow.name
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "prune_logs" {
  depends_on         = [azurerm_storage_account.airflow, azurerm_storage_container.airflow_logs]
  storage_account_id = azurerm_storage_account.airflow.id

  rule {
    name    = "prune-logs"
    enabled = true
    filters {
      prefix_match = ["airflow-logs"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 7
      }
    }
  }
}


resource "tls_private_key" "repository_deploy_private_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "github_repository_deploy_key" "repository_deploy_key" {
  title      = "Repository Deploy Key"
  repository = "arion-airflow-kubernetes"
  key        = tls_private_key.repository_deploy_private_key.public_key_openssh
  read_only  = true
}


resource "kubernetes_namespace" "airflow" {
  depends_on = [azurerm_kubernetes_cluster.main]
  metadata {
    name = "airflow"
  }
}

resource "kubernetes_secret" "airflow_git_ssh" {
  depends_on = [azurerm_kubernetes_cluster.main]
  metadata {
    name      = "airflow-git-ssh-secret"
    namespace = kubernetes_namespace.airflow.metadata[0].name
  }
  data = {
    gitSshKey = tls_private_key.repository_deploy_private_key.private_key_openssh
  }
}

resource "kubernetes_secret" "storage_account_credentials" {
  depends_on = [azurerm_kubernetes_cluster.main]
  metadata {
    name      = "storage-account-credentials"
    namespace = kubernetes_namespace.airflow.metadata[0].name 
  }
  data = {
    azurestorageaccountname = azurerm_storage_account.airflow.name
    azurestorageaccountkey  = azurerm_storage_account.airflow.primary_access_key
  }
  type = "Opaque"
}

resource "kubernetes_persistent_volume" "pv_airflow_logs" {
  metadata {
    name = "pv-airflow-logs"
    labels = {
      type = "local"
    }
  }
  spec {
    capacity = {
      storage = "5Gi"
    }
    access_modes = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name = "azureblob-fuse-premium"
    mount_options = [
      "-o allow_other",
      "--file-cache-timeout-in-seconds=120"
    ]
     persistent_volume_source {
      csi {
        driver       = "blob.csi.azure.com"
        read_only    = false
        volume_handle = "airflow-logs-1"

        volume_attributes = {
          resourceGroup = "arionairflowrg"
          storageAccount = "arionairflowairflowsa"
          containerName = "airflow-logs"
        }

        node_stage_secret_ref {
          name = "storage-account-credentials"
          namespace = "airflow"
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "pvc_airflow_logs" {
  metadata {
    name      = "pvc-airflow-logs"
    namespace = "airflow"
  }
  spec {
    access_modes = ["ReadWriteMany"]
    storage_class_name = "azureblob-fuse-premium"
    resources {
      requests = {
        storage = "5Gi"
      }
    }
    volume_name = kubernetes_persistent_volume.pv_airflow_logs.metadata[0].name
  }
}

resource "helm_release" "airflow" {
  depends_on = [azurerm_kubernetes_cluster.main, kubernetes_persistent_volume_claim.pvc_airflow_logs, kubernetes_persistent_volume.pv_airflow_logs]
  name       = "airflow"
  repository = "https://airflow.apache.org"
  chart      = "airflow"
  namespace  = "airflow"
  values     = [file("${path.module}/../airflow/values.yaml")]
  timeout = 600
  wait = false
  atomic = false
}

resource "kubernetes_service" "airflow_web" {
  metadata {
    name = "airflow-web"
    namespace = "airflow"
  }
  spec {
    selector = {
      component = "webserver"
      release   = "airflow"
      tier      = "airflow"
    }
    port {
      port        = 8080
      target_port = 8080
    }
    type = "LoadBalancer"
  }
}



