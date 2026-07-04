<p align="center">
  <img src="https://s6.imgcdn.dev/YqkO1B.png" alt="DactyVault Banner" width="100%">
</p>

# 🐦 DactyVault Auto Installer

[![Stars](https://img.shields.io/github/stars/hajitazu/dactyvault-installer?style=flat-square)](https://github.com/hajitazu/dactyvault-installer/stargazers)
[![Forks](https://img.shields.io/github/forks/hajitazu/dactyvault-installer?style=flat-square)](https://github.com/hajitazu/dactyvault-installer/network/members)
[![License](https://img.shields.io/github/license/hajitazu/dactyvault-installer?style=flat-square)](LICENSE)

An unofficial one-click automation script to seamlessly install and deploy **DactyVault** onto your Pterodactyl Panel. This installer automatically structures storage directories, injects backend PHP Laravel controllers, provisions administrative Blade frontend components, and synchronizes the automatic cronjob bridges into the host Linux environment instantly.

> [!NOTE]  
> This script is completely unofficial and is not endorsed by or affiliated with the official Pterodactyl Project.

---

## ✨ Key Features

- **Full Automation:** Provisions all necessary dependencies, directory trees, routing scripts, and views in a single execution.
- **DactyVault Core Engine:** High-performance background Bash component designed to compress and ship your server volumes `/var/lib/pterodactyl/volumes` safely onto your mapped cloud storage backend.
- **Smart Retention Strategy (Auto Purge):** Integrated automated engine that scans, flags, and purges obsolete cloud backup files older than 7 days to preserve remote storage space.
- **Precise File Permissions:** Automatically aligns explicit operational permissions (`chmod` and `chown`) for both `root` and `www-data` system actors, avoiding common *Permission Denied* or *500 Internal Server Errors*.
- **Instant Live Refresh:** Programmatically flushes Laravel internal view and route caches via `php artisan` at completion, rendering changes live without requiring manual panel intervention.

---

## 🖥️ Supported Environment

This automation tool is tailored for high-availability systems running production-grade deployments of Pterodactyl Panel 1.x:
- **Ubuntu** (20.04 / 22.04 / 24.04)
- **Debian** (11 / 12)
- *Validated Web Servers:* **Nginx**

---

## 🚀 Deployment Instructions

To trigger the installation process, log into your target Pterodactyl Panel VPS terminal via SSH and guarantee that you have initialized an absolute root session.

Execute the following one-line command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hajitazu/dactyvault-installer/main/install.sh)
