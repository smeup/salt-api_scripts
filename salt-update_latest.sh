#!/bin/bash

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Sono necessari i privilegi di root per eseguire questo script"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "opensuse-leap" && "$ID" != "opensuse-tumbleweed" && "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        echo "Errore: Questo script e' progettato per openSUSE, Debian o Ubuntu. Sistema rilevato: $NAME ($ID)"
        exit 1
    fi
else
    echo "Errore: Impossibile determinare la versione del sistema operativo (/etc/os-release non trovato)."
    exit 1
fi

function usage {
    echo "Usage: $(basename "$0")" >&2
    echo "Aggiorna salt-minion installato via bootstrap all'ultima versione stable disponibile." >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -gt 0 ]; then
    usage
    exit 1
fi

LOG_FILE=$(mktemp)
BACKUP_DIR=$(mktemp -d)

function cleanup {
    rm -f install_salt.sh "$LOG_FILE"
    rm -rf "$BACKUP_DIR"
}

trap cleanup EXIT

function run_step {
    local msg="$1"
    shift

    "$@" > "$LOG_FILE" 2>&1 &
    local pid=$!
    local spin='-\|/'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r[%c] %s..." "${spin:$i:1}" "$msg"
        sleep .1
    done

    wait "$pid"
    local exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        printf "\r\033[K[OK] %s\n" "$msg"
    else
        printf "\r\033[K[ERROR] %s\n" "$msg"
        cat "$LOG_FILE"
        exit 1
    fi
}

function check_existing_installation {
    if ! command -v salt-minion >/dev/null 2>&1 && ! command -v salt-call >/dev/null 2>&1; then
        echo "Errore: salt-minion non risulta installato su questo host."
        return 1
    fi
}

function show_current_version {
    if command -v salt-call >/dev/null 2>&1; then
        salt-call --version 2>/dev/null || salt-minion --version 2>/dev/null || true
    else
        salt-minion --version 2>/dev/null || true
    fi
}

function backup_salt_state {
    mkdir -p "$BACKUP_DIR"

    if [ -d /etc/salt ]; then
        cp -a /etc/salt "$BACKUP_DIR/etc-salt"
    fi

    if [ -f /etc/systemd/system/salt-minion.service ]; then
        cp -a /etc/systemd/system/salt-minion.service "$BACKUP_DIR/salt-minion.service"
    fi
}

function stop_service {
    systemctl stop salt-minion 2>/dev/null || true
    systemctl disable salt-minion 2>/dev/null || true
}

function install_salt_latest {
    if command -v zypper >/dev/null 2>&1; then
        zypper remove -y busybox-which 2>/dev/null || true
    fi

    curl -fsSL https://github.com/saltstack/salt-bootstrap/releases/latest/download/bootstrap-salt.sh -o install_salt.sh
    sh install_salt.sh -P -X stable
}

function restore_salt_state {
    if [ -d "$BACKUP_DIR/etc-salt" ]; then
        mkdir -p /etc/salt

        if [ ! -f /etc/salt/minion ] && [ -f "$BACKUP_DIR/etc-salt/minion" ]; then
            cp -a "$BACKUP_DIR/etc-salt/minion" /etc/salt/minion
        fi

        if [ ! -d /etc/salt/minion.d ] && [ -d "$BACKUP_DIR/etc-salt/minion.d" ]; then
            cp -a "$BACKUP_DIR/etc-salt/minion.d" /etc/salt/minion.d
        fi

        if [ ! -d /etc/salt/pki/minion ] && [ -d "$BACKUP_DIR/etc-salt/pki/minion" ]; then
            mkdir -p /etc/salt/pki
            cp -a "$BACKUP_DIR/etc-salt/pki/minion" /etc/salt/pki/minion
        fi

        if [ ! -f /etc/salt/minion_id ] && [ -f "$BACKUP_DIR/etc-salt/minion_id" ]; then
            cp -a "$BACKUP_DIR/etc-salt/minion_id" /etc/salt/minion_id
        fi
    fi

    if ! systemctl list-unit-files | grep -q '^salt-minion\.service'; then
        if [ -f "$BACKUP_DIR/salt-minion.service" ]; then
            cp -a "$BACKUP_DIR/salt-minion.service" /etc/systemd/system/salt-minion.service
        elif command -v salt-minion >/dev/null 2>&1; then
            cat <<EOF > /etc/systemd/system/salt-minion.service
[Unit]
Description=The Salt Minion
Documentation=man:salt-minion(1) https://docs.saltproject.io/en/latest/contents.html
After=network.target

[Service]
Type=simple
ExecStart=$(command -v salt-minion)
Restart=on-failure
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
        fi
    fi
}

function start_service {
    systemctl daemon-reload
    systemctl enable salt-minion
    systemctl start salt-minion
}

function verify_installation {
    command -v salt-call >/dev/null 2>&1 || return 1
    salt-call --version
}

echo "Versione Salt corrente:"
show_current_version

run_step "Verifica installazione esistente" check_existing_installation
run_step "Backup configurazione e chiavi" backup_salt_state
run_step "Arresto servizio salt-minion" stop_service
run_step "Aggiornamento Salt all'ultima stable" install_salt_latest
run_step "Ripristino configurazione se necessario" restore_salt_state
run_step "Riavvio servizio" start_service
run_step "Verifica versione installata" verify_installation

echo "Aggiornamento completato con successo."
