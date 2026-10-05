#!/usr/bin/env bash
# Install Composer for the current hosting account using a selected PHP CLI.
# PHP snippets and generated shell commands intentionally contain literal dollars.
# shellcheck disable=SC2016
set -euo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: bash install-composer.sh [options]

  --php VERSION|PATH  PHP version (e.g. 8.3) or absolute PHP CLI path.
                     Default: highest compatible EasyApache/CloudLinux PHP,
                     falling back to PHP on PATH.
  --install-dir PATH Store composer.phar here (default: ~/.local/share/cpanel-composer).
  --bin-dir PATH     Store the composer command here (default: ~/bin).
  --no-path          Do not edit shell startup files.
  --force            Download the latest stable Composer even if already installed.
  -h, --help         Show this help.

Run as the cPanel account user, not root. Requires Bash, PHP CLI >= 7.2.5,
and curl or wget. Does not install PHP extensions or project dependencies.
EOF
}

php_choice=''
install_dir="${HOME:?HOME must be set}/.local/share/cpanel-composer"
bin_dir="$HOME/bin"
configure_path=1
force=0
while (($#)); do
    case "$1" in
        --php|--install-dir|--bin-dir)
            if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
                die "$1 requires a value."
            fi
            case "$1" in
                --php) php_choice="$2" ;;
                --install-dir) install_dir="$2" ;;
                --bin-dir) bin_dir="$2" ;;
            esac
            shift 2 ;;
        --no-path) configure_path=0; shift ;;
        --force) force=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1. Use --help." ;;
    esac
done
[[ "$EUID" -ne 0 ]] || die 'Run this script as the cPanel account user, not root.'
[[ "$install_dir" == /* && "$bin_dir" == /* ]] || die 'Installation directories must be absolute paths.'
[[ "$install_dir$bin_dir$php_choice" != *$'\n'* ]] || die 'Paths must not contain newlines.'

probe_php() {
    [[ -x "$1" ]] || return 1
    "$1" -r 'if (PHP_SAPI !== "cli" || PHP_VERSION_ID < 70205) { exit(1); } echo PHP_VERSION_ID;' 2>/dev/null
}

php_bin=''
best=0
consider_php() {
    local candidate="$1" version
    if version=$(probe_php "$candidate") && [[ "$version" =~ ^[0-9]+$ ]] && ((version > best)); then
        best="$version"
        php_bin="$candidate"
    fi
}
if [[ -n "$php_choice" ]]; then
    if [[ "$php_choice" =~ ^[0-9]+\.[0-9]+$ ]]; then
        compact="${php_choice//./}"
        consider_php "/opt/cpanel/ea-php${compact}/root/usr/bin/php"
        consider_php "/opt/alt/php${compact}/usr/bin/php"
        # A matching PATH PHP is useful on other hosting environments.
        path_php=$(command -v php || true)
        if [[ -n "$path_php" ]] && [[ "$("$path_php" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)" == "$php_choice" ]]; then
            consider_php "$path_php"
        fi
    elif [[ "$php_choice" == /* ]]; then
        consider_php "$php_choice"
    else
        die '--php expects a version such as 8.3 or an absolute executable path.'
    fi
else
    for candidate in /opt/cpanel/ea-php*/root/usr/bin/php /opt/alt/php*/usr/bin/php; do
        consider_php "$candidate"
    done
    if [[ -z "$php_bin" ]]; then
        path_php=$(command -v php || true)
        [[ -z "$path_php" ]] || consider_php "$path_php"
    fi
fi
[[ -n "$php_bin" ]] || die 'No matching PHP CLI >= 7.2.5 found. Ask your host to enable it or use --php /absolute/path/to/php.'
[[ "$php_bin" == /* ]] || die 'The selected PHP executable must have an absolute path.'
printf 'Using PHP: %s (%s)\n' "$php_bin" "$("$php_bin" -r 'echo PHP_VERSION;')"
"$php_bin" -r '
$missing = array();
foreach (array("Phar", "hash", "json", "filter", "openssl") as $extension) {
    if (!extension_loaded($extension)) { $missing[] = $extension; }
}
if ($missing) { fwrite(STDERR, "Missing PHP extensions: ".implode(", ", $missing).". Ask your host to enable them for this PHP CLI.\n"); exit(1); }
' || die 'PHP prerequisites failed.'

mkdir -p "$install_dir" "$bin_dir"
install_dir=$(cd "$install_dir" && pwd -P)
bin_dir=$(cd "$bin_dir" && pwd -P)
command_file="$bin_dir/composer"
if [[ -e "$command_file" || -L "$command_file" ]]; then
    if [[ ! -f "$command_file" || -L "$command_file" ]] || ! grep -qx '# Managed by cpanel-composer-installer' "$command_file"; then
        die "$command_file already exists and is not managed by this installer. Use another --bin-dir."
    fi
fi
lock_dir="$install_dir/.install-lock"
mkdir "$lock_dir" 2>/dev/null || die "Another installation may be running. If it was interrupted, remove $lock_dir and retry."
temp_dir=''
wrapper_tmp=''
cleanup() {
    [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
    [[ -z "$wrapper_tmp" ]] || rm -f -- "$wrapper_tmp"
    rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
temp_dir=$(mktemp -d "$install_dir/.setup.XXXXXX")

download() {
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 180 "$1" --output "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --timeout=30 --tries=2 --quiet --output-document="$2" "$1"
    else
        die 'Install curl or wget, or ask your hosting provider to enable one.'
    fi
}
phar="$install_dir/composer.phar"
if [[ -e "$phar" && "$force" -eq 0 ]]; then
    "$php_bin" "$phar" --version || die 'Existing Composer failed. Retry with --force to reinstall.'
    printf 'Keeping the existing Composer installation.\n'
else
    download 'https://composer.github.io/installer.sig' "$temp_dir/installer.sig"
    download 'https://getcomposer.org/installer' "$temp_dir/composer-setup.php"
    "$php_bin" -r '
$expected = trim(file_get_contents($argv[1]));
$actual = hash_file("sha384", $argv[2]);
if (!preg_match("/^[a-f0-9]{96}$/", $expected) || !hash_equals($expected, $actual)) {
    fwrite(STDERR, "Composer installer SHA-384 verification failed.\n"); exit(1);
}
' "$temp_dir/installer.sig" "$temp_dir/composer-setup.php" || die 'Installer verification failed; nothing was installed.'
    "$php_bin" "$temp_dir/composer-setup.php" --2 --install-dir="$temp_dir" --filename=composer.phar
    "$php_bin" "$temp_dir/composer.phar" --version
    chmod 600 "$temp_dir/composer.phar"
    mv -f "$temp_dir/composer.phar" "$phar"
fi

# A Bash wrapper pins PHP and forwards arguments without evaluation.
{
    printf '#!/usr/bin/env bash\n# Managed by cpanel-composer-installer\n'
    printf 'export PATH=%q:"$PATH"\n' "$(dirname "$php_bin")"
    printf 'exec %q %q "$@"\n' "$php_bin" "$phar"
} > "$temp_dir/composer"
chmod 755 "$temp_dir/composer"
# Stage in the destination directory so the final rename is atomic.
wrapper_tmp=$(mktemp "$bin_dir/.composer.XXXXXX")
cp "$temp_dir/composer" "$wrapper_tmp"
chmod 755 "$wrapper_tmp"
mv -f "$wrapper_tmp" "$command_file"

if ((configure_path)); then
    path_line=$(printf 'export PATH=%q:"$PATH" # cpanel-composer-installer' "$bin_dir")
    profile="$HOME/.profile"
    [[ ! -e "$HOME/.bash_profile" ]] || profile="$HOME/.bash_profile"
    [[ -e "$HOME/.bash_profile" || ! -e "$HOME/.bash_login" ]] || profile="$HOME/.bash_login"
    for startup in "$HOME/.bashrc" "$profile"; do
        if ! grep -Fqx "$path_line" "$startup" 2>/dev/null; then
            printf '\n%s\n' "$path_line" >> "$startup"
        fi
    done
    printf 'PATH configured for Bash. Open a new terminal or run:\n'
    printf '  export PATH=%q:"$PATH"\n' "$bin_dir"
fi
"$command_file" --version
printf 'Installed command: %s\n' "$command_file"
printf 'Run composer install from your project directory.\n'
