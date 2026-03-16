#!/bin/bash

if [ $(id -u) -ne 0 ]; then echo "Sono necessari i privilegi di root per eseguire questo script" ; exit 1 ; fi

# Check OS version (CentOS 7 required)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "centos" || "$VERSION_ID" != "7" ]]; then
        echo "Errore: Questo script è progettato specificamente per CentOS 7. Sistema rilevato: $NAME ($VERSION_ID)"
        exit 1
    fi
else
    echo "Errore: Impossibile determinare la versione del sistema operativo (/etc/os-release non trovato)."
    exit 1
fi

# Versione specifica richiesta
SALT_VERSION="3006.23"
SALT_REPO_BASEURL_PRIMARY="https://packages.broadcom.com/artifactory/saltproject-rpm/redhat/7/x86_64/latest/"
SALT_REPO_BASEURL_FALLBACK="https://repo.saltproject.io/salt/py3/redhat/7/x86_64/latest/"
SALT_GPGKEY_PRIMARY="https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public"
SALT_GPGKEY_FALLBACK="https://repo.saltproject.io/salt/py3/redhat/7/x86_64/latest/SALTSTACK-GPG-KEY.pub"
SALT_GPGKEY_LOCAL="/etc/pki/rpm-gpg/RPM-GPG-KEY-saltproject"


BACKUP_DIR=$(mktemp -d)
LOG_FILE=$(mktemp)

# Helper function for pretty output
function run_step {
    local msg="$1"
    shift
    
    "$@" > "$LOG_FILE" 2>&1 &
    local pid=$!
    local spin='-\|/'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[%c] %s..." "${spin:$i:1}" "$msg"
        sleep .1
    done
    
    wait $pid
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        printf "\r\033[K[OK] %s\n" "$msg"
    else
        printf "\r\033[K[ERROR] %s\n" "$msg"
        cat "$LOG_FILE"
        rm "$LOG_FILE"
        exit 1
    fi
}

function show_installation_summary {
    local salt_binary
    salt_binary=$(command -v salt-minion 2>/dev/null || true)
    echo "Metodo installazione previsto: repository package"
    echo "Binario Salt corrente: ${salt_binary:-non trovato}"
    if [ -n "$salt_binary" ]; then
        "$salt_binary" --version 2>/dev/null || true
    fi
    rpm -q salt-minion 2>/dev/null || true
}

function backup_keys {
    echo "Backup delle chiavi in $BACKUP_DIR..."
    if [ -d /etc/salt/pki/minion ]; then
        cp -r /etc/salt/pki/minion "$BACKUP_DIR/"
    fi
    if [ -f /etc/salt/minion_id ]; then
        cp /etc/salt/minion_id "$BACKUP_DIR/"
    fi
    if [ -f /etc/salt/minion.d/id.conf ]; then
        mkdir -p "$BACKUP_DIR/minion.d"
        cp /etc/salt/minion.d/id.conf "$BACKUP_DIR/minion.d/"
    fi
}

function stop_salt_service {
    if ! systemctl list-unit-files | grep -q '^salt-minion\.service'; then
        return 0
    fi

    systemctl disable salt-minion 2>/dev/null || true
    systemctl stop salt-minion 2>/dev/null || true

    # Some old minion processes hang on SIGTERM and force systemd to wait the
    # full TimeoutStopSec before sending SIGKILL.
    if systemctl is-active --quiet salt-minion; then
        systemctl kill --kill-who=all --signal=SIGKILL salt-minion 2>/dev/null || true
        pkill -9 -f '(^|/)?salt-minion($| )' 2>/dev/null || true
        sleep 2
    fi

    systemctl reset-failed salt-minion 2>/dev/null || true
}

function remove_old_salt {
    stop_salt_service
    # Remove both salt-minion and the salt base package to avoid version conflicts
    yum remove -y salt-minion salt
    # Clean yum cache to avoid metadata issues
    yum clean all
    # Clean up old directories but keep config if not replacing completely (we restore anyway)
    rm -rf /etc/salt/pki/minion

    # Also remove possible bootstrap leftovers in mixed installations.
    rm -f /usr/local/bin/salt-minion /usr/local/bin/salt-call
}

function configure_salt_repo {
    local selected_baseurl="$SALT_REPO_BASEURL_PRIMARY"
    local selected_gpgkey="$SALT_GPGKEY_PRIMARY"

    # Old yum/urlgrabber stacks on CentOS 7 can fail on generic Artifactory
    # endpoints that rely on redirects. Probe the explicit repo metadata path.
    if ! curl -L -s -f --connect-timeout 10 "${SALT_REPO_BASEURL_PRIMARY}repodata/repomd.xml" > /dev/null; then
        selected_baseurl="$SALT_REPO_BASEURL_FALLBACK"
        selected_gpgkey="$SALT_GPGKEY_FALLBACK"
    fi

    if ! curl -L -s -f --connect-timeout 10 "$selected_gpgkey" -o "$SALT_GPGKEY_LOCAL"; then
        echo "Errore: impossibile scaricare la chiave GPG Salt da $selected_gpgkey"
        return 1
    fi

    rpm --import "$SALT_GPGKEY_LOCAL"

    # Configure only Salt 3006 LTS repository before any availability checks.
    cat <<EOF > /etc/yum.repos.d/salt.repo
[salt-repo-3006-lts]
name=Salt Repo for Salt v3006 LTS
baseurl=$selected_baseurl
skip_if_unavailable=True
priority=10
enabled=1
enabled_metadata=1
gpgcheck=1
exclude=*3007* *3008* *3009* *3010*
gpgkey=file://$SALT_GPGKEY_LOCAL
EOF

    # Refresh cache after switching repo configuration.
    yum clean all
    yum makecache
}

function install_new_salt_repo {
    configure_salt_repo

    # Install specific version
    yum install -y "salt-minion-$SALT_VERSION*" "salt-$SALT_VERSION*"
}

function verify_installation {
    local resolved_binary
    local version_output

    resolved_binary=$(command -v salt-minion 2>/dev/null || true)
    if [ -z "$resolved_binary" ]; then
        echo "Errore: salt-minion non trovato nel PATH dopo l'aggiornamento."
        return 1
    fi

    echo "Binario salt-minion attivo: $resolved_binary"
    version_output=$("$resolved_binary" --version 2>&1 | tail -n1)
    echo "$version_output"

    if ! echo "$version_output" | grep -q "salt-minion $SALT_VERSION"; then
        echo "Errore: versione Salt attiva diversa da $SALT_VERSION."
        rpm -q salt-minion 2>/dev/null || true
        return 1
    fi
}

function restore_keys {
    mkdir -p /etc/salt/pki/minion
    if [ -d "$BACKUP_DIR/minion" ]; then
        cp -r "$BACKUP_DIR/minion/"* /etc/salt/pki/minion/
        chmod 700 /etc/salt/pki/minion
        chmod 600 /etc/salt/pki/minion/minion.pem 2>/dev/null || true
        chown -R root:root /etc/salt/pki/minion
    fi

    if [ -f "$BACKUP_DIR/minion_id" ]; then
        cp "$BACKUP_DIR/minion_id" /etc/salt/
    fi
    
    if [ -f "$BACKUP_DIR/minion.d/id.conf" ]; then
        mkdir -p /etc/salt/minion.d
        cp "$BACKUP_DIR/minion.d/id.conf" /etc/salt/minion.d/
    fi
    
    # Ensure Master is configured correctly (avoid default 'salt' lookup)
    mkdir -p /etc/salt/minion.d
    echo "master: $MASTER" > /etc/salt/minion.d/master.conf
    
    # Ensure Service is enabled and restarted to load new config
    systemctl enable salt-minion
    systemctl restart salt-minion
}

# Configurazione Master
MASTER="rm.smeup.com"

function configure_repos_centos7 {
    # 1. Disable fastestmirror plugin
    if [ -f /etc/yum/pluginconf.d/fastestmirror.conf ]; then
        sed -i 's/enabled=1/enabled=0/g' /etc/yum/pluginconf.d/fastestmirror.conf 2>/dev/null || true
    fi

    # 2. Restore/Ensure CentOS 7 Vault (original logic)
    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i 's|^baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i 's|^baseurl=http://vault.centos.org|baseurl=https://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    
    # 3. Disable old/broken repos definitively (rmmagent AND legacy saltstack)
    for repo_file in /etc/yum.repos.d/rmmagent.repo /etc/yum.repos.d/saltstack.repo; do
        if [ -f "$repo_file" ]; then
            mv "$repo_file" "${repo_file}.disabled" 2>/dev/null || true
        fi
    done
    # Extra check for labels in other files
    sed -i 's/\[rmmagent\]/\[rmmagent\]\nenabled=0/g' /etc/yum.repos.d/*.repo 2>/dev/null || true
    sed -i 's/\[saltstack\]/\[saltstack\]\nenabled=0/g' /etc/yum.repos.d/*.repo 2>/dev/null || true

    # 4. Fix Damage to EPEL (Revert previous AI changes)
    if [ -f /etc/yum.repos.d/epel.repo ]; then
        sed -i 's/^#metalink/metalink/g' /etc/yum.repos.d/epel.repo
        sed -i 's/^#mirrorlist/mirrorlist/g' /etc/yum.repos.d/epel.repo
        sed -i '/archives.fedoraproject.org/d' /etc/yum.repos.d/epel.repo
    fi

    # 5. Global skip_if_unavailable=1
    for repo in /etc/yum.repos.d/*.repo; do
        if [ -f "$repo" ]; then
            sed -i 's/skip_if_unavailable=.*/skip_if_unavailable=1/g' "$repo"
            if ! grep -q "skip_if_unavailable" "$repo"; then
                sed -i '/^\[.*\]/a skip_if_unavailable=1' "$repo"
            fi
        fi
    done

    yum clean all
    yum makecache || true
}

function install_dependencies {
    local install_needed=false
    
    if ! command -v nc > /dev/null 2>&1; then
        echo "nc non trovato."
        install_needed=true
    fi
    
    if ! command -v curl > /dev/null 2>&1; then
        echo "curl non trovato."
        install_needed=true
    fi
    
    echo "Configurazione repository CentOS 7..."
    configure_repos_centos7

    if [ "$install_needed" = true ]; then
        echo "Installazione dipendenze..."
        yum install -y nc curl
    fi
}

function check_connection {
    local host="$1"
    local port="$2"

    if command -v nc > /dev/null 2>&1; then
        if nc -z -w 5 "$host" "$port" > /dev/null 2>&1; then
            return 0
        fi

        if nc -w 5 "$host" "$port" < /dev/null > /dev/null 2>&1; then
            return 0
        fi
    fi

    if timeout 5 bash -c "</dev/tcp/$host/$port" > /dev/null 2>&1; then
        return 0
    fi

    if [ -n "$(command -v getent 2>/dev/null)" ] && ! getent hosts "$host" > /dev/null 2>&1; then
        echo "Errore: impossibile risolvere il nome host $host."
    else
        echo "Errore: Impossibile raggiungere $host sulla porta $port. Verifica la connessione e riprova."
    fi

    rm -rf "$BACKUP_DIR"
    return 1
}

function check_https_reachability {
    local url="$1"
    # Try to get the HTTP status code. 2xx or 3xx are considered success.
    local status_code
    status_code=$(curl -L -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url")
    
    if [[ ! "$status_code" =~ ^[23] ]]; then
        echo "Errore: Impossibile raggiungere il repository HTTPS: $url (Status code: $status_code)"
        echo "Non aggiorno perche non riesco a raggiungere il sito."
        rm -rf "$BACKUP_DIR"
        return 1
    fi
}

function verify_network {
    install_dependencies
    echo "Verifica connettività verso $MASTER..."
    check_connection "$MASTER" 4505 || return 1
    check_connection "$MASTER" 4506 || return 1
    
    echo "Verifica connettività verso i repository HTTPS..."
    check_https_reachability "https://vault.centos.org" || return 1
    if ! check_https_reachability "https://packages.broadcom.com"; then
        echo "Broadcom non raggiungibile, provo repository ufficiale Salt."
        check_https_reachability "https://repo.saltproject.io" || return 1
    fi
    check_https_reachability "https://github.com" || return 1

    echo "Connettività verso $MASTER e repository OK."
}

function verify_target_package_available {
    local available_minion
    local available_salt

    configure_salt_repo

    available_minion=$(yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt-minion 2>/dev/null | awk '/salt-minion/ {print $2}' | grep "^$SALT_VERSION" | head -n1)
    available_salt=$(yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt 2>/dev/null | awk '/^salt(\.|[[:space:]])/ {print $2}' | grep "^$SALT_VERSION" | head -n1)

    if [ -z "$available_minion" ] || [ -z "$available_salt" ]; then
        echo "Errore: la versione Salt $SALT_VERSION non risulta disponibile dai repository configurati."
        echo "Versioni visibili per salt-minion:"
        yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt-minion 2>/dev/null | awk '/salt-minion/ {print $1, $2}' || true
        echo "Versioni visibili per salt:"
        yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt 2>/dev/null | awk '/^salt(\.|[[:space:]])/ {print $1, $2}' || true
        return 1
    fi
}

# --- Main ---

# -1. Sommario installazione corrente
run_step "Rilevamento installazione corrente" true
show_installation_summary

# 0. Verifica prerequisiti di rete (Installa nc se serve, configurando repo)
run_step "Verifica connettività verso $MASTER" verify_network
run_step "Verifica disponibilita' Salt $SALT_VERSION nei repository" verify_target_package_available

# 1. Backup
run_step "Backup chiavi e configurazione" backup_keys

# 2. Rimuovi vecchia versione
run_step "Rimozione vecchia versione Salt Minion" remove_old_salt

# 3. Installa nuova versione
run_step "Installazione Salt Minion versione $SALT_VERSION da repository" install_new_salt_repo

# 4. Ripristino
run_step "Ripristino chiavi e avvio servizio" restore_keys
run_step "Verifica versione installata" verify_installation

rm -rf "$BACKUP_DIR"
rm -f "$LOG_FILE"
echo "Aggiornamento completato!"
