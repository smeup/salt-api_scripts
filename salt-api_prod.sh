#!/bin/bash

if [ $(id -u) -ne 0 ]; then echo "Sono necessari i privilegi di root per eseguire questo script" ; exit 1 ; fi

function usage {
	echo "Usage: `basename "$0"` [MINION-ID] [USER] [PASSWORD]" >&2
}

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
	usage
	exit 0
fi

if [ $# -ne 3 ]
  then
    usage
    exit 0
fi

MINION=$1
USERNAME=$2
PASSWORD=$3
MASTER=rm.smeup.com
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
    rm -rf /etc/salt/pki/minion
    cat /dev/null > /etc/salt/minion_id
}

function install_jq_pkg {
    if ! command -v jq &> /dev/null; then
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y jq
        elif [ -x "$(command -v dnf)" ]; then
            dnf install -y jq
        elif [ -x "$(command -v zypper)" ]; then
            zypper install -y jq
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq
        else
            echo "Error: Package manager not found. Please install jq manually." >&2
            return 1
        fi
    fi
}

function install_salt_minion {
    curl -L https://github.com/saltstack/salt-bootstrap/releases/latest/download/bootstrap-salt.sh -o install_salt.sh
    sh install_salt.sh -P -X stable 3006.16
}

function stop_services {
    systemctl disable salt-minion
    systemctl stop salt-minion
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
run_step "Installazione in corso di Salt Minion" install_salt_minion

# 4. Stop services (part of installation/cleanup really, but safer to do before config)
run_step "Arresto servizi" stop_services

# 5. Register Minion
run_step "Registrazione in corso" register_minion

# 6. Configure and Start
run_step "Configurazione e avvio servizio" configure_minion

# 7. Final Verification
run_step "Verifica connessione" verify_installation

rm -f "$LOG_FILE" "$API_LOG"
echo "Installazione completata con successo!"
