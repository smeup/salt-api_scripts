#!/bin/bash

if [ $(id -u) -ne 0 ]; then echo "Sono necessari i privilegi di root per eseguire questo script" ; exit 1 ; fi

# Versione specifica richiesta
SALT_VERSION="3006.20"


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

function remove_old_salt {
    systemctl stop salt-minion 2>/dev/null || true
    systemctl disable salt-minion 2>/dev/null || true
    # Remove both salt-minion and the salt base package to avoid version conflicts
    yum remove -y salt-minion salt
    # Clean yum cache to avoid metadata issues
    yum clean all
    # Clean up old directories but keep config if not replacing completely (we restore anyway)
    rm -rf /etc/salt/pki/minion
}

function install_new_salt {
    # Configure only Salt 3006 LTS repository
    cat <<EOF > /etc/yum.repos.d/salt.repo
[salt-repo-3006-lts]
name=Salt Repo for Salt v3006 LTS
baseurl=https://packages.broadcom.com/artifactory/saltproject-rpm/
skip_if_unavailable=True
priority=10
enabled=1
enabled_metadata=1
gpgcheck=1
exclude=*3007* *3008* *3009* *3010*
gpgkey=https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public
EOF
    
    # Refresh cache
    yum clean all
    yum makecache

    # Install specific version
    yum install -y "salt-minion-$SALT_VERSION*" "salt-$SALT_VERSION*"
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
    
    # Ensure Service is enabled
    systemctl enable salt-minion
    systemctl start salt-minion
}

# Configurazione Master
MASTER="rm.smeup.com"

function configure_repos_centos7 {
    # Backup existing repos
    if [ ! -d "/etc/yum.repos.d/backup" ]; then
        mkdir -p /etc/yum.repos.d/backup
        cp /etc/yum.repos.d/CentOS-* /etc/yum.repos.d/backup/ 2>/dev/null || true
    fi
    
    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
    yum clean all
    yum makecache
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
    
    if [ "$install_needed" = true ]; then
        echo "Configurazione repo e installazione dipendenze..."
        configure_repos_centos7
        yum install -y nc curl
    fi
}

function check_connection {
    local host="$1"
    local port="$2"
    if ! nc -z -w 5 "$host" "$port"; then
        echo "Errore: Impossibile raggiungere $host sulla porta $port. Verifica la connessione e riprova."
        rm -rf "$BACKUP_DIR"
        return 1
    fi
}

function verify_network {
    install_dependencies
    echo "Verifica connettività verso $MASTER..."
    check_connection "$MASTER" 4505
    check_connection "$MASTER" 4506
    echo "Connessione verso $MASTER su porte 4505 e 4506 OK."
}

# --- Main ---

# 0. Verifica prerequisiti di rete (Installa nc se serve, configurando repo)
run_step "Verifica connettività verso $MASTER" verify_network

# 1. Backup
run_step "Backup chiavi e configurazione" backup_keys

# 2. Rimuovi vecchia versione
run_step "Rimozione vecchia versione Salt Minion" remove_old_salt

# 3. Installa nuova versione
run_step "Installazione Salt Minion versione $SALT_VERSION" install_new_salt

# 4. Ripristino
run_step "Ripristino chiavi e avvio servizio" restore_keys

rm -rf "$BACKUP_DIR"
rm -f "$LOG_FILE"

echo "Aggiornamento completato! Versione installata:"
salt-minion --version
