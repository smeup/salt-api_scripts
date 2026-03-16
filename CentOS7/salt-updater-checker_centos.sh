#!/bin/bash

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Sono necessari i privilegi di root per eseguire questo script"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "centos" || "$VERSION_ID" != "7" ]]; then
        echo "Errore: Questo script e' progettato specificamente per CentOS 7. Sistema rilevato: $NAME ($VERSION_ID)"
        exit 1
    fi
else
    echo "Errore: Impossibile determinare la versione del sistema operativo (/etc/os-release non trovato)."
    exit 1
fi

SALT_VERSION="3006.23"
SALT_REPO_BASEURL_PRIMARY="https://packages.broadcom.com/artifactory/saltproject-rpm/"
SALT_GPGKEY_PRIMARY="https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public"
SALT_GPGKEY_LOCAL="/etc/pki/rpm-gpg/RPM-GPG-KEY-saltproject"
CENTOS_VAULT_BASEURL="http://vault.centos.org"

LOG_FILE=$(mktemp)

function cleanup {
    rm -f "$LOG_FILE"
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

function show_installation_summary {
    local salt_binary
    salt_binary=$(command -v salt-minion 2>/dev/null || true)
    echo "Modalita': repo-checker"
    echo "Binario Salt corrente: ${salt_binary:-non trovato}"
    if [ -n "$salt_binary" ]; then
        "$salt_binary" --version 2>/dev/null || true
    fi
    rpm -q salt-minion 2>/dev/null || true
    rpm -q salt 2>/dev/null || true
}

function configure_repos_centos7 {
    if [ -f /etc/yum/pluginconf.d/fastestmirror.conf ]; then
        sed -i 's/enabled=1/enabled=0/g' /etc/yum/pluginconf.d/fastestmirror.conf 2>/dev/null || true
    fi

    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^#baseurl=http://mirror.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^baseurl=http://mirror.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^baseurl=https://vault.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true
    sed -i "s|^baseurl=http://vault.centos.org|baseurl=${CENTOS_VAULT_BASEURL}|g" /etc/yum.repos.d/CentOS-* 2>/dev/null || true

    for repo_file in /etc/yum.repos.d/rmmagent.repo /etc/yum.repos.d/saltstack.repo; do
        if [ -f "$repo_file" ]; then
            mv "$repo_file" "${repo_file}.disabled" 2>/dev/null || true
        fi
    done

    sed -i 's/\[rmmagent\]/\[rmmagent\]\nenabled=0/g' /etc/yum.repos.d/*.repo 2>/dev/null || true
    sed -i 's/\[saltstack\]/\[saltstack\]\nenabled=0/g' /etc/yum.repos.d/*.repo 2>/dev/null || true

    if [ -f /etc/yum.repos.d/epel.repo ]; then
        sed -i 's/^#metalink/metalink/g' /etc/yum.repos.d/epel.repo
        sed -i 's/^#mirrorlist/mirrorlist/g' /etc/yum.repos.d/epel.repo
        sed -i '/archives.fedoraproject.org/d' /etc/yum.repos.d/epel.repo
    fi

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

function check_repo_reachability {
    local url="$1"
    local status_code

    status_code=$(curl -L -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url")

    if [[ ! "$status_code" =~ ^[23] ]]; then
        echo "Errore: Impossibile raggiungere il repository: $url (Status code: $status_code)"
        return 1
    fi
}

function configure_salt_repo {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Errore: curl non trovato. E' necessario per scaricare la chiave GPG del repository Salt."
        return 1
    fi

    if ! curl -L -s -f --connect-timeout 10 "$SALT_GPGKEY_PRIMARY" -o "$SALT_GPGKEY_LOCAL"; then
        echo "Errore: impossibile scaricare la chiave GPG Salt da $SALT_GPGKEY_PRIMARY"
        return 1
    fi

    rpm --import "$SALT_GPGKEY_LOCAL"

    cat <<EOF > /etc/yum.repos.d/salt.repo
[salt-repo-3006-lts]
name=Salt Repo for Salt v3006 LTS
baseurl=$SALT_REPO_BASEURL_PRIMARY
skip_if_unavailable=True
priority=10
enabled=1
enabled_metadata=1
gpgcheck=1
exclude=*3007* *3008* *3009* *3010*
gpgkey=file://$SALT_GPGKEY_LOCAL
EOF

    yum clean all
    yum makecache
}

function verify_target_package_available {
    local available_minion
    local available_salt

    check_repo_reachability "$CENTOS_VAULT_BASEURL" || return 1
    check_repo_reachability "https://packages.broadcom.com" || return 1
    configure_salt_repo

    available_minion=$(yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt-minion 2>/dev/null | awk '/salt-minion/ {print $2}' | grep "^$SALT_VERSION" | head -n1)
    available_salt=$(yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt 2>/dev/null | awk '/^salt(\.|[[:space:]])/ {print $2}' | grep "^$SALT_VERSION" | head -n1)

    if [ -z "$available_minion" ] || [ -z "$available_salt" ]; then
        echo "Errore: la versione Salt $SALT_VERSION non risulta disponibile dai repository configurati."
        return 1
    fi

    echo "Versione disponibile trovata:"
    echo "salt-minion $available_minion"
    echo "salt $available_salt"
}

run_step_stateful "Rilevamento installazione corrente" show_installation_summary
run_step "Configurazione repository CentOS 7" configure_repos_centos7
run_step "Verifica disponibilita' Salt $SALT_VERSION nei repository" verify_target_package_available

echo "Repo-check completato con successo."
