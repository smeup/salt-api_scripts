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

function usage {
	echo "Usage: `basename "$0"` [MINION-ID] [USER] [PASSWORD]" >&2
	echo "Note: If arguments are omitted, they will be requested interactively." >&2
}

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
	usage
	exit 0
fi

# 0. Check MTU
function check_mtu {
    # Find the default interface
    local interface
    interface=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    
    if [ -z "$interface" ]; then
        return 0
    fi
    
    local mtu
    if [ -f "/sys/class/net/$interface/mtu" ]; then
        mtu=$(cat "/sys/class/net/$interface/mtu")
    else
        return 0
    fi
    
    if [ "$mtu" -gt 1500 ]; then
        printf "\n\033[1;33m[ATTENZIONE] L'MTU dell'interfaccia $interface è $mtu (superiore a 1500).\n"
        printf "Questo potrebbe causare problemi di registrazione del minion.\033[0m\n\n"
    fi
}
check_mtu

# Arguments are now optional
if [ $# -gt 0 ] && [ $# -ne 3 ]; then
    usage
    exit 0
fi

MINION=$1
USERNAME=$2
PASSWORD=$3

if [ -z "$MINION" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
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
fi

if [ -z "$MINION" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    printf "\nErrore: Tutti i campi (minion, username, password) sono obbligatori.\n" >&2
    exit 1
fi

MASTER=rm.smeup.com
CENTOS_VAULT_BASEURL="http://vault.centos.org"
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
    if [ -d /etc/salt ]; then
        rm -rf /etc/salt/pki/minion 2>/dev/null || true
        if [ -f /etc/salt/minion_id ]; then
            : > /etc/salt/minion_id
        fi
    fi
}

function configure_repos_centos7 {
    # 1. Disable fastestmirror plugin (causes issues on EOL)
    if [ -f /etc/yum/pluginconf.d/fastestmirror.conf ]; then
        sed -i 's/enabled=1/enabled=0/g' /etc/yum/pluginconf.d/fastestmirror.conf 2>/dev/null || true
    fi

    # 2. Restore/Ensure CentOS 7 Vault (original logic)
    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^#baseurl=http://mirror.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^baseurl=http://mirror.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^baseurl=https://vault.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^baseurl=http://vault.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    
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
    # Non-blocking makecache
    yum makecache || true
}

function install_dependencies {
    if ! rpm -qa | grep -q epel-release; then
        yum install epel-release -y || true
    fi
    
    if ! command -v jq &> /dev/null; then
        if ! yum install jq -y; then
            echo "Tentativo di installazione manuale di jq..."
            curl -L https://github.com/stedolan/jq/releases/latest/download/jq-linux64 -o /usr/local/bin/jq && chmod +x /usr/local/bin/jq
            ln -sf /usr/local/bin/jq /usr/bin/jq 2>/dev/null || true
        fi
    fi
}

function setup_salt_repo {
    if [ ! -f /etc/yum.repos.d/salt.repo ]; then
        curl -fsSL https://github.com/saltstack/salt-install-guide/releases/latest/download/salt.repo | tee /etc/yum.repos.d/salt.repo
        yum clean all
        yum makecache
    fi
}

function install_salt_minion {
    yum install -y "salt-minion-$SELECTED_VERSION"
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

    echo "$curl_out" > "$API_LOG"

    if [ $curl_exit_code -eq 6 ] || echo "$curl_out" | grep -q "Could not resolve host"; then
        echo "Registrazione fallita, impossibile raggiungere l'host ${MASTER}"
        return 1
    fi

    if echo "$curl_out" | grep -qE "401 Unauthorized|Authentication failure"; then
        echo "Registrazione fallita, utente o password errata"
        return 1
    fi
    
    if echo "$curl_out" | jq -e '.return[0].data.success' > /dev/null 2>&1 || echo "$curl_out" | jq -e '.return[0].data.return.success' > /dev/null 2>&1; then
        mkdir -p /etc/salt/pki/minion
        chmod 700 /etc/salt/pki/minion
        echo "$curl_out" | jq -r '.return[0].data.return.priv' > /etc/salt/pki/minion/minion.pem
        echo "$curl_out" | jq -r '.return[0].data.return.pub' > /etc/salt/pki/minion/minion.pub
        chmod 600 /etc/salt/pki/minion/minion.pem
    else
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

function select_salt_version {
    echo "Recupero versioni Salt Minion disponibili..."
    
    local versions
    if ! versions=$(yum list --showduplicates salt-minion 2>/dev/null | grep "salt-minion" | awk '{print $2}' | sort -r | uniq); then
         echo "Impossibile recuperare le versioni. Verifica la connessione o i repository."
         exit 1
    fi

    if [ -z "$versions" ]; then
        echo "Errore: Nessuna versione di salt-minion trovata."
        exit 1
    fi
    
    IFS=$'\n' read -r -d '' -a version_array <<< "$versions"

    echo "Versioni disponibili:"
    PS3="Seleziona una versione (inserisci il numero): "
    select version in "${version_array[@]}" "Inserimento Manuale"; do
        if [ "$version" == "Inserimento Manuale" ]; then
            read -p "Inserisci versione manuale: " SELECTED_VERSION < /dev/tty
            break
        elif [ -n "$version" ]; then
            SELECTED_VERSION="$version"
            break
        else
            echo "Selezione non valida."
        fi
    done < /dev/tty
    echo "Versione selezionata: $SELECTED_VERSION"
}

# --- Main Execution ---

# 1. Clean environment
run_step "Pulizia configurazione precedente" clean_environment

# 2. Configure Repos (CentOS 7 specific)
run_step "Configurazione Repository CentOS 7 (Vault)" configure_repos_centos7

# 3. Install Dependencies
run_step "Installazione dipendenze (epel, jq)" install_dependencies

# 4. Setup Salt Repo
run_step "Configurazione Repository Salt" setup_salt_repo

# 5. Select Version
select_salt_version

# 6. Install Salt Minion
run_step "Installazione Salt Minion $SELECTED_VERSION" install_salt_minion

# 7. Stop services
run_step "Arresto servizi" stop_services

# 8. Register Minion
run_step "Registrazione Minion su ${MASTER}" register_minion

# 9. Configure and Start
run_step "Configurazione e avvio servizio" configure_minion

# 10. Final Verification
run_step "Verifica finale connessione" verify_installation

rm -f "$LOG_FILE" "$API_LOG"
echo "Installazione completata con successo!"
