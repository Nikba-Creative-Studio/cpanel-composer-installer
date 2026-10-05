# cPanel Composer Installer

Install Composer for an individual cPanel account with one Bash command. No root access is required.

cPanel stopped bundling Composer in version 130. This script automates a per-user installation using the official Composer installer, verifies its SHA-384 checksum, and creates a `composer` command that uses your selected PHP CLI.

## Requirements

- SSH access or **cPanel → Terminal**, enabled by your hosting provider.
- Bash and PHP **CLI 7.2.5 or newer**, with the Phar, hash, json, filter, and openssl extensions.
- `curl` or `wget`, with HTTPS access to `getcomposer.org` and `composer.github.io`.
- A writable home directory and enough hosting memory/disk space for Composer and your dependencies.

Run this script as your **cPanel account user**. It rejects root execution. It does not require WHM, change server packages, enable PHP extensions, or install project dependencies automatically.

## Quick start

Download or upload `install-composer.sh` from this repository to your account, then open cPanel Terminal or connect over SSH:

```bash
bash install-composer.sh --php 8.3
export PATH="$HOME/bin:$PATH"
composer --version
```

Alternatively, clone the repository if Git is available:

```bash
git clone https://github.com/Nikba-Creative-Studio/cpanel-composer-installer.git
cd cpanel-composer-installer
bash install-composer.sh --php 8.3
export PATH="$HOME/bin:$PATH"
```

For a private repository, cloning requires GitHub access. You can also download the script while signed in and upload it using cPanel File Manager.

Replace `8.3` with the PHP version used by your project. Find the website's PHP version in **cPanel → MultiPHP Manager** or your host's PHP Selector. The script does not infer a domain's PHP configuration.

To choose PHP automatically:

```bash
bash install-composer.sh
```

Automatic selection uses the highest compatible PHP CLI under EasyApache or CloudLinux paths, then falls back to `php` on `PATH`. This may differ from your website's PHP version; specifying `--php` is recommended.

## Install PHP libraries

From the directory containing your project's `composer.json`:

```bash
cd "$HOME/public_html/my-project"
composer install
```

To add a library:

```bash
composer require phpmailer/phpmailer
```

Load the generated autoloader in your PHP application:

```php
require __DIR__ . '/vendor/autoload.php';
```

For deployment with an existing `composer.lock`:

```bash
composer install --no-dev --prefer-dist --optimize-autoloader
composer check-platform-reqs --no-dev
```

Composer can execute project scripts and plugins during dependency installation. Run it for projects and dependencies you trust.

## Options

| Option | Purpose |
| --- | --- |
| `--php 8.3` | Select a specific installed PHP major/minor version. |
| `--php /absolute/path/to/php` | Use a specific PHP CLI executable. |
| `--install-dir /absolute/path` | Change the Composer PHAR directory. |
| `--bin-dir /absolute/path` | Change where the `composer` wrapper is created. |
| `--no-path` | Leave shell startup files untouched. |
| `--force` | Reinstall using the latest stable Composer 2 release. |
| `--help` | Display usage. |

Examples:

```bash
# EasyApache PHP
bash install-composer.sh --php /opt/cpanel/ea-php83/root/usr/bin/php

# CloudLinux alternate PHP
bash install-composer.sh --php /opt/alt/php83/usr/bin/php

# Custom directories without editing shell profiles
bash install-composer.sh --php 8.3 \
  --install-dir "$HOME/tools/composer" \
  --bin-dir "$HOME/tools/bin" --no-path
"$HOME/tools/bin/composer" --version

# Download the latest stable Composer again
bash install-composer.sh --php 8.3 --force
```

## How it works

1. Selects PHP CLI and checks basic PHP prerequisites.
2. Creates a private staging directory and an installation lock.
3. Downloads the official installer and its current SHA-384 checksum over HTTPS.
4. Verifies the checksum before executing the installer.
5. Installs Composer 2 and verifies that it runs before replacing the PHAR.
6. Creates a Bash wrapper that pins the PHP executable and forwards your arguments.
7. Adds the command directory to Bash startup files unless `--no-path` is supplied.

Default files:

```text
~/bin/composer
~/.local/share/cpanel-composer/composer.phar
```

The script appends a marked PATH line to `~/.bashrc` and the active Bash login profile (`~/.bash_profile`, `~/.bash_login`, or `~/.profile`). Repeating the same installation does not duplicate these lines. Other shells require manual PATH configuration.

Rerunning preserves the existing Composer PHAR, checks it with the selected PHP, and regenerates the wrapper. Use `--force` to refresh Composer. An unrelated command already present at the target `composer` path is never overwritten. Keep the installation outside publicly served website directories.

## Troubleshooting

**No matching PHP CLI found:** Ask your host to enable the requested PHP version and shell access. Use an absolute PHP path if your host uses another layout. A CGI/FastCGI binary is not a PHP CLI binary.

**Missing extensions or installer settings errors:** The script lists missing basic extensions, and the official installer checks additional settings. Ask your host to adjust the selected CLI PHP configuration. Inspect it with:

```bash
/opt/cpanel/ea-php83/root/usr/bin/php --ini
/opt/cpanel/ea-php83/root/usr/bin/php -m
```

Libraries may require extra extensions such as mbstring, intl, or zip. Installing Composer does not install those extensions. PHP extensions and disabled functions can differ between CLI and the website.

**`composer: command not found`:** Open a new Bash terminal, run `export PATH="$HOME/bin:$PATH"`, or invoke `"$HOME/bin/composer"` directly. Use your custom bin directory if you selected one. Existing aliases/functions named `composer` may take precedence; inspect them with `type -a composer`.

**Checksum or download failure:** Check outbound HTTPS access and CA certificates. Retry later. The script never disables TLS verification or bypasses an installer checksum failure.

**Installation lock exists:** Check that another installation is not running. After an interrupted installation, remove the reported `.install-lock` directory with `rmdir` and retry.

**Existing command conflict:** Choose another `--bin-dir`, or inspect and move your existing command yourself before rerunning.

**Hosting process or memory restrictions:** Your provider may restrict subprocesses or available memory. The script cannot override hosting policies. If shell access is unavailable, install dependencies locally or in CI using compatible PHP and extensions, then deploy the project including `vendor/`.

## Development

```bash
bash -n install-composer.sh
python3 -m unittest discover -s tests -v
```

The automated tests use isolated home directories and mock downloads/PHP. They cover verification failures, interrupted updates, argument forwarding, repeat runs, and command conflicts without requiring a cPanel server. A live cPanel account is still needed to confirm your provider's specific setup.

## Official references

- [cPanel: Install Composer on version 130 and higher](https://support.cpanel.net/hc/en-us/articles/33990336418583-How-to-install-composer-on-cPanel-version-130-and-higher)
- [Composer download and installer options](https://getcomposer.org/download/)
- [Installing Composer programmatically](https://getcomposer.org/doc/faqs/how-to-install-composer-programmatically.md)

## License

MIT. See [LICENSE](LICENSE).
