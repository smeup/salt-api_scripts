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
    echo "Aggiorna salt-minion alla versione fissa 3006.23." >&2
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
SALT_VERSION="3006.23"
INSTALL_METHOD=""
SALT_BINARY=""
BEFORE_VERSION=""
AFTER_VERSION=""

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

function run_step_stateful {
    local msg="$1"
    shift

    printf "[..] %s...\n" "$msg"

    if "$@" > "$LOG_FILE" 2>&1; then
        printf "\033[K[OK] %s\n" "$msg"
    else
        printf "\033[K[ERROR] %s\n" "$msg"
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

function get_salt_version {
    local binary_path="${1:-}"

    if [ -n "$binary_path" ] && [ -x "$binary_path" ]; then
        "$binary_path" --version 2>/dev/null | head -n1
        return 0
    fi

    if command -v salt-call >/dev/null 2>&1; then
        salt-call --version 2>/dev/null | head -n1 || true
    elif command -v salt-minion >/dev/null 2>&1; then
        salt-minion --version 2>/dev/null | head -n1 || true
    fi
}

function detect_installation_method {
    if [[ "$ID" = "opensuse-leap" || "$ID" = "opensuse-tumbleweed" ]]; then
        INSTALL_METHOD="bootstrap"
        SALT_BINARY=$(command -v salt-minion 2>/dev/null || command -v salt-call 2>/dev/null || true)
        if [ -z "$SALT_BINARY" ]; then
            echo "Errore: impossibile determinare il binario Salt installato."
            return 1
        fi
        return 0
    fi

    local repo_markers=(
        /etc/apt/sources.list.d/salt.list
        /etc/apt/sources.list.d/salt.sources
        /etc/apt/keyrings/salt-archive-keyring.gpg
        /etc/zypp/repos.d/salt.repo
    )
    local bootstrap_markers=(
        /usr/local/bin/salt-minion
        /usr/local/bin/salt-call
    )

    SALT_BINARY=$(command -v salt-minion 2>/dev/null || command -v salt-call 2>/dev/null || true)
    if [ -z "$SALT_BINARY" ]; then
        echo "Errore: impossibile determinare il binario Salt installato."
        return 1
    fi

    if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$SALT_BINARY" >/dev/null 2>&1; then
        INSTALL_METHOD="repo"
        return 0
    fi

    if command -v rpm >/dev/null 2>&1 && rpm -qf "$SALT_BINARY" >/dev/null 2>&1; then
        INSTALL_METHOD="repo"
        return 0
    fi

    local marker
    for marker in "${repo_markers[@]}"; do
        if [ -e "$marker" ]; then
            INSTALL_METHOD="repo"
            return 0
        fi
    done

    for marker in "${bootstrap_markers[@]}"; do
        if [ -e "$marker" ]; then
            INSTALL_METHOD="bootstrap"
            return 0
        fi
    done

    INSTALL_METHOD="bootstrap"
}

function show_installation_summary {
    echo "Metodo installazione rilevato: $INSTALL_METHOD"
    echo "Binario Salt usato per verifica: $SALT_BINARY"
    BEFORE_VERSION=$(get_salt_version "$SALT_BINARY")
    if [ -n "$BEFORE_VERSION" ]; then
        echo "Versione Salt corrente: $BEFORE_VERSION"
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

function install_salt_latest_bootstrap {
    if command -v zypper >/dev/null 2>&1; then
        zypper remove -y busybox-which 2>/dev/null || true
    fi

    curl -fsSL https://github.com/saltstack/salt-bootstrap/releases/latest/download/bootstrap-salt.sh -o install_salt.sh
    sh install_salt.sh -P -X stable "$SALT_VERSION"
}

function extract_salt_version_number {
    local version_output="${1:-}"
    printf '%s\n' "$version_output" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

function install_salt_latest_repo {
    local packages

    if command -v apt-get >/dev/null 2>&1; then
        packages=$(dpkg-query -W -f='${binary:Package}\n' 'salt*' 2>/dev/null | sort -u | tr '\n' ' ')
        if [ -z "$packages" ]; then
            echo "Errore: nessun pacchetto Salt trovato tramite dpkg."
            return 1
        fi

        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y $(printf '%s\n' "$packages" | tr ' ' '\n' | sed "/^$/d; s/\$/=$SALT_VERSION*/")
        return 0
    fi

    if command -v zypper >/dev/null 2>&1; then
        packages=$(rpm -qa | grep '^salt' | sort -u | tr '\n' ' ')
        if [ -z "$packages" ]; then
            echo "Errore: nessun pacchetto Salt trovato tramite rpm."
            return 1
        fi

        zypper refresh
        zypper install -y $(printf '%s\n' "$packages" | tr ' ' '\n' | sed "/^$/d; s/\$/-$SALT_VERSION*/")
        return 0
    fi

    echo "Errore: package manager non supportato per aggiornamento da repository."
    return 1
}

function install_salt_latest {
    if [ "$INSTALL_METHOD" = "repo" ]; then
        install_salt_latest_repo
    else
        install_salt_latest_bootstrap
    fi
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
    local resolved_binary
    local after_version_number

    if [ "$INSTALL_METHOD" = "repo" ]; then
        resolved_binary=$(command -v salt-minion 2>/dev/null || true)
        if [ -n "$resolved_binary" ]; then
            if command -v dpkg-query >/dev/null 2>&1 && ! dpkg-query -S "$resolved_binary" >/dev/null 2>&1; then
                echo "Warning: il binario in PATH ($resolved_binary) non appartiene a un pacchetto."
            fi
            if command -v rpm >/dev/null 2>&1 && ! rpm -qf "$resolved_binary" >/dev/null 2>&1; then
                echo "Warning: il binario in PATH ($resolved_binary) non appartiene a un pacchetto."
            fi
        fi
    fi

    AFTER_VERSION=$(get_salt_version "$SALT_BINARY")
    if [ -z "$AFTER_VERSION" ]; then
        echo "Errore: impossibile determinare la versione Salt dopo l'aggiornamento."
        return 1
    fi

    after_version_number=$(extract_salt_version_number "$AFTER_VERSION")
    if [ -z "$after_version_number" ]; then
        echo "Errore: impossibile estrarre il numero di versione da: $AFTER_VERSION"
        return 1
    fi

    if [ "$after_version_number" != "$SALT_VERSION" ]; then
        echo "Errore: versione rilevata dopo l'aggiornamento: $after_version_number, attesa: $SALT_VERSION"
        return 1
    fi

    echo "$AFTER_VERSION"
}

run_step "Verifica installazione esistente" check_existing_installation
run_step_stateful "Rilevamento metodo installazione" detect_installation_method
show_installation_summary
run_step "Backup configurazione e chiavi" backup_salt_state
run_step "Arresto servizio salt-minion" stop_service
if [ "$INSTALL_METHOD" = "bootstrap" ]; then
    run_step "Aggiornamento Salt alla versione $SALT_VERSION via bootstrap" install_salt_latest
    run_step "Ripristino configurazione se necessario" restore_salt_state
else
    run_step "Aggiornamento Salt alla versione $SALT_VERSION dai repository configurati" install_salt_latest
fi
run_step "Riavvio servizio" start_service
run_step_stateful "Verifica versione installata" verify_installation

if [ -n "$BEFORE_VERSION" ] && [ -n "$AFTER_VERSION" ] && [ "$BEFORE_VERSION" = "$AFTER_VERSION" ]; then
    echo "Nota: la versione rilevata prima e dopo l'aggiornamento e' la stessa."
fi

echo "Aggiornamento completato con successo."

