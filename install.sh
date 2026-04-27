#!/bin/bash

# BookStack Installation Script for AlmaLinux 9
# Target: Configurable via bookstack.properties (Default: /var/www/bookstack)

set -e

# Ensure running as root for package installation
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or using sudo."
  exit 1
fi

current_dir=$(pwd)
properties_file="$current_dir/bookstack.properties"

if [ ! -f "$properties_file" ]; then
    echo "Error: $properties_file not found."
    echo "Please create it from bookstack.properties.template before running this script."
    exit 1
fi

# Source the properties file
source "$properties_file"

# Set defaults if not provided in properties
install_dir=${install_dir:-/var/www/bookstack}
db_host=${db_host:-127.0.0.1}
web_user=${web_user:-nginx}
web_group=${web_group:-nginx}

echo "--- 1. Checking Repositories ---"
if ! rpm -q remi-release > /dev/null 2>&1; then
    echo "Adding Remi repository for PHP 8.3..."
    dnf install -y epel-release
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
fi

# Enable PHP 8.3 if not already enabled
if [[ $(dnf module list php --enabled | grep "remi-8.3") == "" ]]; then
    echo "Enabling PHP 8.3 module..."
    dnf module reset php -y
    dnf module enable php:remi-8.3 -y
fi

echo "--- 2. Checking and Installing Dependencies ---"
packages=(
    nginx
    mariadb-server
    mariadb
    git
    unzip
    composer
    php-fpm
    php-mysqlnd
    php-gd
    php-xml
    php-mbstring
    php-zip
    php-curl
    php-intl
    php-bcmath
    mod_ssl
)

missing_packages=()
for pkg in "${packages[@]}"; do
    if ! rpm -q "$pkg" > /dev/null 2>&1; then
        missing_packages+=("$pkg")
    fi
done

if [ ${#missing_packages[@]} -gt 0 ]; then
    echo "Installing missing dependencies: ${missing_packages[*]}"
    dnf install -y "${missing_packages[@]}"
else
    echo "All core dependencies are already installed."
fi

echo "--- 3. Ensuring Services are Started ---"
for service in nginx mariadb php-fpm; do
    if ! systemctl is-active --quiet "$service"; then
        echo "Starting $service..."
        systemctl enable --now "$service"
    else
        echo "$service is already running."
    fi
done

echo "--- 4. Configuring Firewall ---"
if systemctl is-active --quiet firewalld; then
    echo "Opening HTTP and HTTPS ports in firewalld..."
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
else
    echo "firewalld is not active, skipping firewall configuration."
fi

echo "--- 5. Configuring Database ---"
# Prompt for MariaDB root password
read -s -p "Enter MariaDB root password: " mariadb_root_pass
echo ""

# Use 127.0.0.1 to force TCP and avoid unix_socket issues
# We drop and recreate the user to ensure no conflicting plugin settings exist
mysql -u root -p"$mariadb_root_pass" <<EOF
CREATE DATABASE IF NOT EXISTS $db_name;
DROP USER IF EXISTS '$db_user'@'localhost';
DROP USER IF EXISTS '$db_user'@'127.0.0.1';
CREATE USER '$db_user'@'127.0.0.1' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

echo "--- 6. Downloading BookStack to $install_dir ---"
if [ ! -d "$install_dir" ]; then
    mkdir -p "$install_dir"
fi

temp_dir=$(mktemp -d)
git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch "$temp_dir"
cp -rn "$temp_dir"/. "$install_dir"/
rm -rf "$temp_dir"

echo "--- 7. Installing PHP Dependencies ---"
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --working-dir="$install_dir"

echo "--- 8. Configuring Environment ---"
if [ ! -f "$install_dir/.env" ]; then
    cp "$install_dir/.env.example" "$install_dir/.env"
fi

# Always update .env values to match properties
# Using '#' as sed delimiter to avoid issues with '/' in passwords or URLs
sed -i "s#^APP_URL=.*#APP_URL=$app_url#" "$install_dir/.env"
sed -i "s#^DB_DATABASE=.*#DB_DATABASE=$db_name#" "$install_dir/.env"
sed -i "s#^DB_USERNAME=.*#DB_USERNAME=$db_user#" "$install_dir/.env"
sed -i "s#^DB_PASSWORD=.*#DB_PASSWORD=$db_pass#" "$install_dir/.env"
sed -i "s#^DB_HOST=.*#DB_HOST=127.0.0.1#" "$install_dir/.env"

echo "--- 9. Finalizing Application Setup ---"
cd "$install_dir"
php artisan key:generate --force
php artisan migrate --force

echo "--- 10. Setting Permissions ---"
# Set ownership for the entire installation directory
chown -R "$web_user":"$web_group" "$install_dir"

# Ensure specific folders and their contents have 775 permissions
chmod -R 775 "$install_dir/storage" "$install_dir/bootstrap/cache" "$install_dir/public/uploads"

echo "--- 11. Generating SSL Certificates ---"
# Check if PHP-FPM is using the same user (typical on AlmaLinux)
if grep -q "user = $web_user" /etc/php-fpm.d/www.conf; then
    echo "PHP-FPM user matches: $web_user"
else
    echo "WARNING: PHP-FPM might be running as a different user than $web_user."
    echo "Check /etc/php-fpm.d/www.conf and set user/group to $web_user."
fi

domain_name=$(echo "$app_url" | sed -e 's|^[^/]*//||' -e 's|/.*$||')
cert_path="/etc/pki/tls/certs/bookstack.crt"
key_path="/etc/pki/tls/private/bookstack.key"

if [ ! -f "$cert_path" ]; then
    echo "Generating self-signed certificate for $domain_name..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key_path" \
        -out "$cert_path" \
        -subj "/C=US/ST=State/L=City/O=Organization/OU=IT/CN=$domain_name"
    chmod 600 "$key_path"
else
    echo "SSL certificate already exists at $cert_path, skipping generation."
fi

echo "--- 12. Configuring Nginx Site ---"
# Extract domain from app_url for server_name
domain_name=$(echo "$app_url" | sed -e 's|^[^/]*//||' -e 's|/.*$||')

echo "Deploying Nginx configuration for $domain_name..."
cp "$current_dir/bookstack.conf.template" "/etc/nginx/conf.d/bookstack.conf"

# Update server_name and root path in the deployed config
sed -i "s#server_name bookstack.example.com;#server_name $domain_name;#g" "/etc/nginx/conf.d/bookstack.conf"
sed -i "s#root /var/www/bookstack/public;#root $install_dir/public;#g" "/etc/nginx/conf.d/bookstack.conf"

echo "Checking Nginx configuration..."
nginx -t

echo "Restarting Nginx..."
systemctl restart nginx

echo "-------------------------------------------------------"
echo " Installation Complete!"
echo "-------------------------------------------------------"
echo " Installation Path: $install_dir"
echo " Domain Configured: $domain_name"
echo " Database Name:     $db_name"
echo " Database User:     $db_user"
echo "-------------------------------------------------------"
echo " Default Credentials:"
echo " Email:    admin@admin.com"
echo " Password: password"
echo "-------------------------------------------------------"
echo " Your BookStack instance is now live at: $app_url"
echo "-------------------------------------------------------"
