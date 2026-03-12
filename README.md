# Salt API scripts

This repository is for install salt-minion automatically, using salt-api, with a script.

To use these scripts, please follow this guide.
Before run this scripts, check the host rm.smeup.com is reachable and on machine, the ports 22, 4505 and 4506 is opened.

When you run the script, it will check the MTU of the network interface and will warn you if it is greater than 1500.

**In this version, the script is interactive, so you need to provide the minion id, username and password after launch the script, not at the end of the command!**

## Connect to Production installation

### Standard Installation (All supported OS except CentOS 7)

```bash
curl -fsSL https://bit.ly/saltapi | sudo bash -s
```

## Connect to Testing installation

First, add on your host file this value:

```bash
18.201.195.159     rm-test.smeup.com
```

### Register minion

```bash
curl -fsSL https://bit.ly/saltapitest | sudo bash -s
```

### Legacy command to register minion

```bash
curl -fsSL https://bit.ly/saltapitest | sudo bash -s MINION_ID USERNAME PASSWORD
```

### Testing script behavior

`salt-api_test.sh` keeps the interactive master selection, with default `rm-test.smeup.com`.

The Salt version is fixed to `3006.23`.

## Utility

### Update Salt SUSE/Debian/Ubuntu

Per aggiornare un `salt-minion` gia' installato, usando backup conservativo di configurazione e chiavi, con target fisso `3006.23`:

```bash
curl -fsSL https://bit.ly/saltapi-upd | sudo bash -s
```

In locale:

```bash
sudo bash salt-updater_suse.sh
```

### Check master response

```bash
curl https://rm.smeup.com/login -H 'Accept: application/x-yaml' -d username=USERNAME -d password=PASSWORD -d eauth=pam
```

### Test SSH key generation

```bash
curl https://rm.smeup.com/run -H "Accept: application/json" -d username=USERNAME -d password=PASSWORD -d eauth='pam' -d client='wheel' -d fun='key.gen' -d id_='test-minion-manuale'
```

### Test connectivity

```bash
curl https://rm.smeup.com/run -H 'Accept: application/x-yaml' -H 'Content-type: application/json' -d '[{"client":"local","tgt":"MINION_ID","fun":"test.ping","username":"USERNAME","password":"PASSWORD","eauth": "pam"}]'
```

If you want to try connection with testing installation, change "rm.smeup.com/run" with "salt.smeup.com/run"

## Legacy / EOL Support

### CentOS 7 (Exclusive Support)

**Important:** For CentOS 7, you **must** use this specific command. The standard script does not support CentOS 7.

```bash
curl -fsSL https://bit.ly/saltapicentos7 | sudo bash -s
```

### CentOS 7 Updater Script

This script automates the upgrade of Salt Minion on CentOS 7 to version **3006.23**, preserving existing keys and configuration.

**Prerequisites:**

- Root privileges.
- Connectivity to `rm.smeup.com` on ports 4505 and 4506.

**Usage:**

```bash
curl -fsSL https://bit.ly/saltupdate | sudo bash -s
```

In locale:

```bash
sudo bash CentOS7/updater_centos.sh
```

**Tested and working on:**

- salt-minion 3003.3
- salt-minion 2018.3.3
- salt-minion 2019.2.0

**What it does:**

1. Checks connectivity to the Master.
2. Backs up keys and config.
3. Removes old Salt Minion.
4. Installs Salt Minion 3006.23.
5. Restores keys and restarts the service.
