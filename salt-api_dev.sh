#!/bin/bash

if [ $(id -u) -ne 0 ]; then echo "Sono necessari i privilegi di root per eseguire questo script" ; exit 1 ; fi

# Check OS version (openSUSE, Debian, Ubuntu required)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "opensuse-leap" && "$ID" != "opensuse-tumbleweed" && "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        echo "Errore: Questo script è progettato per openSUSE, Debian o Ubuntu. Sistema rilevato: $NAME ($ID)"
        exit 1
    fi
else
    echo "Errore: Impossibile determinare la versione del sistema operativo (/etc/os-release non trovato)."
    exit 1
fi

function usage {
	echo "Usage: `basename "$0"` [MINION-ID] [USER] [PASSWORD] [MASTER] [SALT-VERSION]" >&2
	echo "Note: If arguments are omitted, they will be requested interactively." >&2
}

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
	usage
	exit 0
fi

# 0. Check MTU (moved here to show alert before input)
function check_mtu {
    # Find the default interface
    local interface
    interface=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    
    if [ -z "$interface" ]; then
        echo "Warning: Could not determine the default network interface."
        return 0
    fi
    
    local mtu
    if [ -f "/sys/class/net/$interface/mtu" ]; then
        mtu=$(cat "/sys/class/net/$interface/mtu")
    else
        echo "Warning: Could not read MTU for interface $interface."
        return 0
    fi
    
    echo "Interface: $interface, MTU: $mtu"
    
    if [ "$mtu" -gt 1500 ]; then
        printf "\n\033[1;33m[ATTENZIONE] L'MTU dell'interfaccia $interface è $mtu (superiore a 1500).\n"
        printf "Questo potrebbe causare problemi di registrazione del minion.\033[0m\n\n"
    fi
}
check_mtu

MINION=$1
USERNAME=$2
PASSWORD=$3
MASTER=$4
SALT_VERSION=$5

# Interactive Prompt Logic
if [ -z "$MINION" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$MASTER" ] || [ -z "$SALT_VERSION" ]; then
    # Se lo script è in pipe, dobbiamo leggere dal terminale (/dev/tty)
    # Altrimenti possiamo usare lo stdin standard (/dev/stdin)
    [ -t 0 ] && TTY="/dev/stdin" || TTY="/dev/tty"

    if [ -z "$MINION" ]; then
        printf "Inserisci il nome del minion (es. s<id>.001): " > /dev/tty
        read -r MINION < "$TTY"
    fi

    if [ -z "$USERNAME" ]; then
        printf "Inserisci username: " > /dev/tty
        read -r USERNAME < "$TTY"
    fi

    if [ -z "$PASSWORD" ]; then
        printf "Inserisci password: " > /dev/tty
        if [ "$TTY" = "/dev/tty" ]; then
            stty -echo < /dev/tty
            read -r PASSWORD < /dev/tty
            stty echo < /dev/tty
            printf "\n" > /dev/tty
        else
            read -s -r PASSWORD
            printf "\n"
        fi
    fi

    if [ -z "$MASTER" ]; then
        DEFAULT_MASTER="rm-test.smeup.com"
        printf "Inserisci indirizzo Salt Master [$DEFAULT_MASTER]: " > /dev/tty
        read -r MASTER < "$TTY"
        MASTER=${MASTER:-$DEFAULT_MASTER}
    fi

    if [ -z "$SALT_VERSION" ]; then
        echo "Caricamento versioni disponibili..." > /dev/tty
        RAW_VERSIONS=$(curl -s "https://api.github.com/repos/saltstack/salt/tags?per_page=100" | grep "name" | cut -d '"' -f 4 | sed 's/^v//')
        DEFAULT_VERSION="3006.23"

        if [ -n "$RAW_VERSIONS" ]; then
            VERSIONS_3006=$(echo "$RAW_VERSIONS" | grep '^3006\.' | sort -Vr | head -n 6)

            if [ -n "$VERSIONS_3006" ]; then
                DEFAULT_VERSION=$(echo "$VERSIONS_3006" | head -n 1)
                echo "Ultime versioni Salt 3006.x disponibili:" > /dev/tty
                echo "$VERSIONS_3006" | nl -w1 -s'. ' > /dev/tty
            else
                echo "Nessuna versione 3006.x trovata, uso default." > /dev/tty
            fi
        else
            echo "Impossibile recuperare lista versioni, uso default." > /dev/tty
        fi

        printf "Inserisci versione Salt [%s]: " "$DEFAULT_VERSION" > /dev/tty
        read -r SALT_VERSION < "$TTY"
        SALT_VERSION=${SALT_VERSION:-$DEFAULT_VERSION}
    fi
fi

if [ -z "$MINION" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$MASTER" ] || [ -z "$SALT_VERSION" ]; then
    printf "\nErrore: Tutti i campi sono obbligatori.\n" >&2
    exit 1
fi

LOG_FILE=$(mktemp)
API_LOG=$(mktemp)

# Helper function for pretty output with spinner
function run_step {
    local msg="$1"
    shift
    
    # Run command in background, redirecting output
    "$@" > "$LOG_FILE" 2>&1 &
    local pid=$!
    
    local spin='-\|/'
    local i=0
    
    # Loop continuously while the process is running
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
        echo "Error details:"
        cat "$LOG_FILE"
        rm "$LOG_FILE"
        rm -f "$API_LOG"
        exit 1
    fi
}

function clean_environment {
    # Only attempt cleanup if /etc/salt exists — avoid errors on fresh installs
    if [ -d /etc/salt ]; then
        rm -rf /etc/salt/pki/minion 2>/dev/null || true
        if [ -f /etc/salt/minion_id ]; then
            : > /etc/salt/minion_id
        fi
    fi
}

function install_jq_pkg {
    if ! command -v jq &> /dev/null; then
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y jq
        elif [ -x "$(command -v zypper)" ]; then
            zypper install -y jq
        else
            echo "Error: Package manager not found (Apt or Zypper required). Please install jq manually." >&2
            return 1
        fi
    fi
}

function install_salt_minion {
    # Fix for OpenSUSE 16 conflict: remove busybox-which to allow salt-minion RPM install
    if command -v zypper > /dev/null; then
        zypper remove -y busybox-which 2>/dev/null || true
    fi

    echo "Installazione versione Salt: $SALT_VERSION"
    curl -L https://github.com/saltstack/salt-bootstrap/releases/latest/download/bootstrap-salt.sh -o install_salt.sh
    # Use -P (pip based install if needed, though usually packages) - actually, -P allows pip packages, but 
    # bootstrap usually defaults to packages. 
    # The original script used: sh install_salt.sh -P -X stable 3006.16
    # effectively passing "stable <version>" as arguments
    sh install_salt.sh -P -X stable "$SALT_VERSION"
}

function stop_services {
    systemctl disable salt-minion 2>/dev/null || true
    systemctl stop salt-minion 2>/dev/null || true
}

function register_minion {
    # Delete potential old keys first
    curl -sS -X POST "https://${MASTER}/run" \
        -H "Accept: application/json" \
        -d username="${USERNAME}" \
        -d password="${PASSWORD}" \
        -d eauth="pam" \
        -d client="wheel" \
        -d fun="key.delete" \
        -d match="${MINION}" > /dev/null 2>&1

    # Generate and accept new key
    # Capture both stdout and stderr to parse for errors
    local curl_out
    curl_out=$(curl -sS -X POST "https://${MASTER}/run" \
        -H "Accept: application/json" \
        -d username="${USERNAME}" \
        -d password="${PASSWORD}" \
        -d eauth="pam" \
        -d client="wheel" \
        -d fun="key.gen_accept" \
        -d id_="${MINION}" \
        -d force=True 2>&1)
    
    local curl_exit_code=$?

    # Save output for logging context if needed (though we mostly want to replaceit)
    echo "$curl_out" > "$API_LOG"

    # Check for network errors (curl code 6 is Could not resolve host)
    if [ $curl_exit_code -eq 6 ] || echo "$curl_out" | grep -q "Could not resolve host"; then
        echo "Registrazione fallita, impossibile raggiungere l'host ${MASTER}"
        return 1
    fi

    # Check for auth errors (HTTP 401 or specific text)
    if echo "$curl_out" | grep -qE "401 Unauthorized|Authentication failure"; then
        echo "Registrazione fallita, utente o password errata"
        return 1
    fi
    
    # Verify success using jq
    if echo "$curl_out" | jq -e '.return[0].data.success' > /dev/null 2>&1 || echo "$curl_out" | jq -e '.return[0].data.return.success' > /dev/null 2>&1; then
        mkdir -p /etc/salt/pki/minion
        chmod 700 /etc/salt/pki/minion
        echo "$curl_out" | jq -r '.return[0].data.return.priv' > /etc/salt/pki/minion/minion.pem
        echo "$curl_out" | jq -r '.return[0].data.return.pub' > /etc/salt/pki/minion/minion.pub
        chmod 600 /etc/salt/pki/minion/minion.pem
    else
        # If we got here, it's not a standard auth/net error but still failed Logic or JSON parse
        echo "Errore imprevisto durante la registrazione. Risposta API:"
        cat "$API_LOG"
        return 1
    fi
}

function configure_minion {
    mkdir -p /etc/salt/minion.d
    printf "master: ${MASTER}\nid: ${MINION}" > /etc/salt/minion.d/id.conf

    # Check if service exists
    if ! systemctl list-unit-files | grep -q salt-minion.service; then
        echo "Service unit missing, creating it..."
        local BIN_PATH=$(command -v salt-minion)
        if [ -z "$BIN_PATH" ]; then
             echo "Error: salt-minion binary not found!"
             return 1
        fi
        
        cat <<EOF > /etc/systemd/system/salt-minion.service
[Unit]
Description=The Salt Minion
Documentation=man:salt-minion(1) https://docs.saltproject.io/en/latest/contents.html
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH
Restart=on-failure
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    systemctl enable salt-minion
    systemctl start salt-minion
}

function verify_installation {
    salt-call test.ping
}

# --- Main Execution ---

# 1. Clean environment
run_step "Pulizia configurazione precedente" clean_environment

# 2. Install jq
run_step "Installazione in corso di jq" install_jq_pkg

# 3. Install Salt Minion
run_step "Installazione in corso di Salt Minion ($SALT_VERSION)" install_salt_minion

# 4. Stop services (part of installation/cleanup really, but safer to do before config)
run_step "Arresto servizi" stop_services

# 5. Register Minion
run_step "Registrazione in corso su $MASTER" register_minion

# 6. Configure and Start
run_step "Configurazione e avvio servizio" configure_minion

# 7. Final Verification
run_step "Verifica connessione" verify_installation

rm -f install_salt.sh
rm -f "$LOG_FILE" "$API_LOG"
echo "Installazione completata con successo!"
