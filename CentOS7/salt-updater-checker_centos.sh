#!/bin/bash

set -u

RC_SUCCESS=0
RC_NOT_ROOT=10
RC_OS_RELEASE_MISSING=11
RC_UNSUPPORTED_OS=12
RC_STEP_SHOW_INSTALLATION=20
RC_STEP_CONFIGURE_CENTOS_REPOS=30
RC_STEP_VERIFY_TARGET_VERSION=40
RC_REPO_CENTOS_UNREACHABLE=41
RC_REPO_SALT_UNREACHABLE=42
RC_CURL_MISSING=43
RC_SALT_GPG_DOWNLOAD_FAILED=44
RC_SALT_GPG_IMPORT_FAILED=45
RC_SALT_REPO_CONFIG_FAILED=46
RC_YUM_CACHE_REFRESH_FAILED=47
RC_TARGET_VERSION_NOT_AVAILABLE=48

function get_ret_label {
    local exit_code="$1"

    case "$exit_code" in
        0) echo "SUCCESS" ;;
        10) echo "NOT_ROOT" ;;
        11) echo "OS_RELEASE_MISSING" ;;
        12) echo "UNSUPPORTED_OS" ;;
        20) echo "STEP_SHOW_INSTALLATION_FAILED" ;;
        30) echo "STEP_CONFIGURE_CENTOS_REPOS_FAILED" ;;
        40) echo "STEP_VERIFY_TARGET_VERSION_FAILED" ;;
        41) echo "REPO_CENTOS_UNREACHABLE" ;;
        42) echo "REPO_SALT_UNREACHABLE" ;;
        43) echo "CURL_MISSING" ;;
        44) echo "SALT_GPG_DOWNLOAD_FAILED" ;;
        45) echo "SALT_GPG_IMPORT_FAILED" ;;
        46) echo "SALT_REPO_CONFIG_FAILED" ;;
        47) echo "YUM_CACHE_REFRESH_FAILED" ;;
        48) echo "TARGET_VERSION_NOT_AVAILABLE" ;;
        *) echo "UNKNOWN_ERROR" ;;
    esac
}

function print_retcode_info {
    local exit_code="$1"

    echo "RET_CODE=$exit_code RET_LABEL=$(get_ret_label "$exit_code")"
}

function fail {
    local exit_code="$1"
    local message="$2"

    echo "$message"
    print_retcode_info "$exit_code"
    exit "$exit_code"
}

if [ "$(id -u)" -ne 0 ]; then
    fail "$RC_NOT_ROOT" "Sono necessari i privilegi di root per eseguire questo script"
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "centos" || "$VERSION_ID" != "7" ]]; then
        fail "$RC_UNSUPPORTED_OS" "Errore: Questo script e' progettato specificamente per CentOS 7. Sistema rilevato: $NAME ($VERSION_ID)"
    fi
else
    fail "$RC_OS_RELEASE_MISSING" "Errore: Impossibile determinare la versione del sistema operativo (/etc/os-release non trovato)."
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
    local step_exit_code="$1"
    local msg="$2"
    shift
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
    local command_exit_code=$?

    if [ "$command_exit_code" -eq 0 ]; then
        printf "\r\033[K[OK] %s\n" "$msg"
    else
        printf "\r\033[K[ERROR] %s\n" "$msg"
        cat "$LOG_FILE"
        print_retcode_info "$step_exit_code"
        exit "$step_exit_code"
    fi
}

function run_step_stateful {
    local step_exit_code="$1"
    local msg="$2"
    shift
    shift

    printf "[..] %s...\n" "$msg"

    if "$@" > "$LOG_FILE" 2>&1; then
        printf "\033[K[OK] %s\n" "$msg"
    else
        printf "\033[K[ERROR] %s\n" "$msg"
        cat "$LOG_FILE"
        print_retcode_info "$step_exit_code"
        exit "$step_exit_code"
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
    local exit_code="$2"
    local status_code

    status_code=$(curl -L -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url")

    if [[ ! "$status_code" =~ ^[23] ]]; then
        echo "Errore: Impossibile raggiungere il repository: $url (Status code: $status_code)"
        return "$exit_code"
    fi
}

function configure_salt_repo {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Errore: curl non trovato. E' necessario per scaricare la chiave GPG del repository Salt."
        return "$RC_CURL_MISSING"
    fi

    if ! curl -L -s -f --connect-timeout 10 "$SALT_GPGKEY_PRIMARY" -o "$SALT_GPGKEY_LOCAL"; then
        echo "Errore: impossibile scaricare la chiave GPG Salt da $SALT_GPGKEY_PRIMARY"
        return "$RC_SALT_GPG_DOWNLOAD_FAILED"
    fi

    if ! rpm --import "$SALT_GPGKEY_LOCAL"; then
        echo "Errore: impossibile importare la chiave GPG Salt."
        return "$RC_SALT_GPG_IMPORT_FAILED"
    fi

    if ! cat <<EOF > /etc/yum.repos.d/salt.repo
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
    then
        echo "Errore: impossibile scrivere /etc/yum.repos.d/salt.repo"
        return "$RC_SALT_REPO_CONFIG_FAILED"
    fi

    yum clean all
    if ! yum makecache; then
        echo "Errore: yum makecache fallito dopo la configurazione del repository Salt."
        return "$RC_YUM_CACHE_REFRESH_FAILED"
    fi
}

function verify_target_package_available {
    local available_minion
    local available_salt

    check_repo_reachability "$CENTOS_VAULT_BASEURL" "$RC_REPO_CENTOS_UNREACHABLE" || return $?
    check_repo_reachability "https://packages.broadcom.com" "$RC_REPO_SALT_UNREACHABLE" || return $?
    configure_salt_repo || return $?

    available_minion=$(yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt-minion 2>/dev/null | awk '/salt-minion/ {print $2}' | grep "^$SALT_VERSION" | head -n1)
    available_salt=$(yum --disablerepo='*' --enablerepo='salt-repo-3006-lts' list --showduplicates salt 2>/dev/null | awk '/^salt(\.|[[:space:]])/ {print $2}' | grep "^$SALT_VERSION" | head -n1)

    if [ -z "$available_minion" ] || [ -z "$available_salt" ]; then
        echo "Errore: la versione Salt $SALT_VERSION non risulta disponibile dai repository configurati."
        return "$RC_TARGET_VERSION_NOT_AVAILABLE"
    fi

    echo "Versione disponibile trovata:"
    echo "salt-minion $available_minion"
    echo "salt $available_salt"
}

run_step_stateful "$RC_STEP_SHOW_INSTALLATION" "Rilevamento installazione corrente" show_installation_summary
run_step "$RC_STEP_CONFIGURE_CENTOS_REPOS" "Configurazione repository CentOS 7" configure_repos_centos7
run_step "$RC_STEP_VERIFY_TARGET_VERSION" "Verifica disponibilita' Salt $SALT_VERSION nei repository" verify_target_package_available

echo "Repo-check completato con successo."
print_retcode_info "$RC_SUCCESS"
exit "$RC_SUCCESS"
