# Script Flowcharts

Questo file riassume, con diagrammi Mermaid, cosa fa ogni script della repo.

## Mappa veloce

| Script | Scopo |
|---|---|
| `salt-api_prod.sh` | Registra e installa un minion Salt su openSUSE/Debian/Ubuntu verso `rm.smeup.com` |
| `salt-api_test.sh` | Registra e installa un minion Salt su openSUSE/Debian/Ubuntu verso un master test scelto o predefinito |
| `salt-updater_suse.sh` | Aggiorna Salt su openSUSE/Debian/Ubuntu alla `3006.23` preservando configurazione e chiavi |
| `CentOS7/salt-api_centos7.sh` | Registra e installa un minion Salt su CentOS 7, con scelta interattiva della versione |
| `CentOS7/salt-updater_centos.sh` | Aggiorna Salt su CentOS 7 alla `3006.23` usando repo Broadcom/Vault e ripristinando chiavi |
| `CentOS7/salt-updater-checker_centos.sh` | Non aggiorna nulla: verifica solo che CentOS 7 e i repository permettano l'upgrade target |

## 1. `salt-api_prod.sh`

```mermaid
flowchart TD
    A[Avvio script] --> B{Utente root?}
    B -- No --> BX[Esce con errore]
    B -- Si --> C{OS supportato? openSUSE Debian Ubuntu}
    C -- No --> CX[Esce con errore]
    C -- Si --> D[Controlla MTU interfaccia di default]
    D --> E{Argomenti completi? minion user password}
    E -- No --> F[Chiede dati in modo interattivo]
    E -- Si --> G[Imposta MASTER rm.smeup.com]
    F --> G
    G --> H[Pulizia ambiente Salt locale]
    H --> I[Installa jq via apt o zypper]
    I --> J[Scarica bootstrap-salt.sh]
    J --> K[Installa salt-minion 3006.23]
    K --> L[Disabilita e ferma servizio salt-minion]
    L --> M[Chiama salt-api: key.delete vecchia chiave]
    M --> N[Chiama salt-api: key.gen_accept]
    N --> O{Registrazione API riuscita?}
    O -- No --> OX[Mostra errore rete auth o risposta API]
    O -- Si --> P[Scrive minion.pem e minion.pub]
    P --> Q[Scrive /etc/salt/minion.d/id.conf]
    Q --> R{Unit systemd esiste?}
    R -- No --> S[Crea salt-minion.service]
    R -- Si --> T[Abilita e avvia servizio]
    S --> T
    T --> U[Esegue salt-call test.ping]
    U --> V{Ping ok?}
    V -- No --> VX[Esce con errore]
    V -- Si --> W[Pulizia file temporanei e fine]
```

## 2. `salt-api_test.sh`

```mermaid
flowchart TD
    A[Avvio script] --> B{Utente root e OS supportato?}
    B -- No --> BX[Esce con errore]
    B -- Si --> C[Controlla MTU]
    C --> D[Legge minion user password master]
    D --> E{MASTER valorizzato?}
    E -- No --> F[Usa default rm-test.smeup.com]
    E -- Si --> G[Continua]
    F --> G
    G --> H[Pulizia configurazione Salt locale]
    H --> I[Installa jq]
    I --> J[Scarica bootstrap Salt]
    J --> K[Installa salt-minion 3006.23]
    K --> L[Ferma e disabilita servizio]
    L --> M[Elimina eventuale chiave precedente sul master]
    M --> N[Genera e accetta nuova chiave via API]
    N --> O{API ok?}
    O -- No --> OX[Errore rete auth o JSON]
    O -- Si --> P[Salva chiavi locali del minion]
    P --> Q[Configura id.conf con master e id]
    Q --> R{Manca unit systemd?}
    R -- Si --> S[La crea]
    R -- No --> T[Abilita e avvia servizio]
    S --> T
    T --> U[Esegue salt-call test.ping]
    U --> V[Fine]
```

Differenza principale rispetto al `prod`: qui il master non è fisso, può essere passato come quarto argomento oppure inserito a mano, con default `rm-test.smeup.com`.

## 3. `salt-updater_suse.sh`

```mermaid
flowchart TD
    A[Avvio script] --> B{Utente root e OS supportato?}
    B -- No --> BX[Esce con errore]
    B -- Si --> C[Verifica che Salt sia gia installato]
    C --> D[Rileva metodo installazione]
    D --> E{Repo package o bootstrap?}
    E -- Repo --> F[Salva binario e versione attuale]
    E -- Bootstrap --> F
    F --> G[Backup di /etc/salt e unit systemd]
    G --> H[Ferma e disabilita salt-minion]
    H --> I{Installazione da repo?}
    I -- Si --> J[Aggiorna pacchetti Salt a 3006.23]
    I -- No --> K[Scarica bootstrap-salt e reinstalla 3006.23]
    J --> L[Ripristina config chiavi e service se mancano]
    K --> L
    L --> M[daemon-reload enable start]
    M --> N[Legge versione finale]
    N --> O{Versione finale = 3006.23?}
    O -- No --> OX[Errore e uscita]
    O -- Si --> P[Messaggio aggiornamento completato]
```

Dettaglio importante:

- Se trova un'installazione da repository usa `apt-get` o `zypper`.
- Su SUSE può aggiungere/abilitare il repo Broadcom `salt-repo-lts`.
- Se trova un'installazione bootstrap, reinstalla via `bootstrap-salt.sh`.

## 4. `CentOS7/salt-api_centos7.sh`

```mermaid
flowchart TD
    A[Avvio script] --> B{Utente root?}
    B -- No --> BX[Esce con errore]
    B -- Si --> C{OS = CentOS 7?}
    C -- No --> CX[Esce con errore]
    C -- Si --> D[Controlla MTU]
    D --> E[Legge minion user password]
    E --> F[Pulizia config Salt locale]
    F --> G[Corregge repo CentOS 7 verso Vault]
    G --> H[Disabilita repo legacy rotti]
    H --> I[Installa dipendenze epel e jq]
    I --> J[Configura salt.repo]
    J --> K[Recupera versioni disponibili di salt-minion]
    K --> L[Utente seleziona la versione]
    L --> M[Installa salt-minion versione scelta]
    M --> N[Ferma e disabilita servizio]
    N --> O[Elimina vecchia chiave sul master]
    O --> P[Genera e accetta nuova chiave via API]
    P --> Q{Registrazione riuscita?}
    Q -- No --> QX[Errore rete auth o API]
    Q -- Si --> R[Salva chiavi locali]
    R --> S[Scrive id.conf con master rm.smeup.com]
    S --> T[Abilita e avvia servizio]
    T --> U[Esegue salt-call test.ping]
    U --> V[Fine]
```

Questo script è quello più “manuale” lato installazione: prima sistema i repository di CentOS 7, poi ti fa scegliere interattivamente quale versione di `salt-minion` installare.

## 5. `CentOS7/salt-updater_centos.sh`

```mermaid
flowchart TD
    A[Avvio script] --> B{Utente root e CentOS 7?}
    B -- No --> BX[Esce con errore]
    B -- Si --> C[Mostra installazione Salt corrente]
    C --> D[Verifica rete verso master e repo]
    D --> E[Corregge repo CentOS 7 verso Vault]
    E --> F[Controlla raggiungibilita di Vault Broadcom GitHub]
    F --> G[Configura repo Salt 3006 LTS e chiave GPG]
    G --> H{Versione 3006.23 disponibile?}
    H -- No --> HX[Esce con errore]
    H -- Si --> I[Backup chiavi minion e configurazione]
    I --> J[Ferma servizio salt-minion]
    J --> K[Rimuove vecchi pacchetti salt e salt-minion]
    K --> L[Pulisce cache yum e vecchi binari bootstrap]
    L --> M[Tenta installazione da yum]
    M --> N{Installazione yum riuscita?}
    N -- Si --> O[Continua]
    N -- No --> P[Scarica rpm salt e salt-minion manualmente]
    P --> O
    O --> Q[Ripristina chiavi minion_id e id.conf]
    Q --> R[Scrive master.conf con rm.smeup.com]
    R --> S[Enable e restart servizio]
    S --> T[Verifica che salt-minion sia 3006.23]
    T --> U{Versione corretta?}
    U -- No --> UX[Esce con errore]
    U -- Si --> V[Fine aggiornamento]
```

Questo è lo script di upgrade vero per CentOS 7.

## 6. `CentOS7/salt-updater-checker_centos.sh`

```mermaid
flowchart TD
    A[Avvio script] --> B{Utente root e CentOS 7?}
    B -- No --> BX[Esce con codice errore dedicato]
    B -- Si --> C[Mostra installazione Salt corrente]
    C --> D[Configura repo CentOS 7 verso Vault]
    D --> E[Verifica raggiungibilita Vault]
    E --> F[Verifica raggiungibilita packages.broadcom.com]
    F --> G{curl disponibile?}
    G -- No --> GX[Esce con codice RC_CURL_MISSING]
    G -- Si --> H[Scarica chiave GPG Salt]
    H --> I[Importa chiave rpm]
    I --> J[Scrive salt.repo 3006 LTS]
    J --> K[Fa yum makecache]
    K --> L[Cerca salt e salt-minion 3006.23]
    L --> M{Entrambi trovati?}
    M -- No --> MX[Esce con RC_TARGET_VERSION_NOT_AVAILABLE]
    M -- Si --> N[Stampa successo e RET_CODE=0]
```

Questo script serve come “pre-check”: verifica in anticipo se un host CentOS 7 è pronto per l'aggiornamento, senza rimuovere o installare nulla.

## Relazioni tra gli script

```mermaid
flowchart LR
    A[salt-api_prod.sh] --> A1[Installazione e registrazione minion su Linux moderni]
    B[salt-api_test.sh] --> A1
    C[salt-updater_suse.sh] --> C1[Aggiornamento Salt su Linux moderni]
    D[CentOS7/salt-api_centos7.sh] --> D1[Installazione e registrazione minion su CentOS 7]
    E[CentOS7/salt-updater_centos.sh] --> E1[Aggiornamento Salt su CentOS 7]
    F[CentOS7/salt-updater-checker_centos.sh] --> F1[Pre-check upgrade CentOS 7]

    A1 --> G[Usano salt-api per creare chiavi e configurare il minion]
    D1 --> G
    C1 --> H[Preservano chiavi e configurazione esistenti]
    E1 --> H
    F1 --> I[Verifica solo repo e prerequisiti]
```

