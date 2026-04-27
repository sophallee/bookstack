# BookStack Installation on AlmaLinux 9

This directory contains a script to automate the installation and configuration of BookStack on AlmaLinux 9.

## Files
- `install.sh`: The main installation script.
- `bookstack.conf.template`: A sample Nginx configuration file.
- `bookstack.properties.template`: Template for installation variables.

## Prerequisites
- AlmaLinux 9
- Root or sudo access

## Quick Start

1.  **Configure Properties:**
    Copy the template and edit it with your database and application settings. The default `install_dir` is `/var/www/bookstack`.
    ```bash
    cp bookstack.properties.template bookstack.properties
    vi bookstack.properties
    ```

2.  **Make the script executable:**
    ```bash
    chmod +x install.sh
    ```

3.  **Run the script as root:**
    ```bash
    sudo ./install.sh
    ```

4.  **Nginx, SSL, and Firewall:**
    The installer automatically:
    - Opens HTTP/HTTPS ports in `firewalld`.
    - Generates a self-signed SSL certificate for your domain (if one doesn't exist).
    - Deploys the Nginx configuration to `/etc/nginx/conf.d/bookstack.conf`.
    - Sets the `server_name` based on your `app_url`.
    - Restarts Nginx.

    If you need to make manual changes later:
    ```bash
    sudo vi /etc/nginx/conf.d/bookstack.conf
    sudo systemctl restart nginx
    ```

5.  **SELinux (Optional but recommended):**
    If SELinux is enabled, set the correct contexts for the standard installation path:
    ```bash
    sudo chcon -Rt httpd_sys_content_t /var/www/bookstack/public
    sudo chcon -Rt httpd_sys_rw_content_t /var/www/bookstack/storage /var/www/bookstack/bootstrap/cache /var/www/bookstack/public/uploads
    setsebool -P httpd_can_network_connect_db 1
    ```

## Default Login
- **Email:** `admin@admin.com`
- **Password:** `password`

**Note:** Change the password immediately after logging in.
