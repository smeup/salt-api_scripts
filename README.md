# Salt API scripts

Per una mappa visuale dei flussi degli script, vedi `SCRIPT_FLOWCHARTS.md`.

This repository is for install salt-minion automatically, using salt-api, with a script.

To use these scripts, please follow this guide.
Before run this scripts, check the host rm.smeup.com is reachable and on machine, the ports 22, 4505 and 4506 is opened.

When you run the script, it will check the MTU of the network interface and will warn you if it is greater than 1500.

**In this version, the script is interactive, so you need to provide the minion id, username and password after launch the script, not at the end of the command!**

## Register Minion

### Standard Installation (All supported OS except CentOS 7)

```bash
curl -fsSL https://bit.ly/saltapi | sudo bash -s
```

### CentOS 7

```bash
curl -fsSL https://bit.ly/saltapicentos7 | sudo bash -s
```

## Update Minion

### SUSE/Debian/Ubuntu

```bash
curl -fsSL https://bit.ly/saltupds | sudo bash -s
```

### CentOS 7

```bash
curl -fsSL https://bit.ly/saltupdc | sudo bash -s
```

**Tested and working on:**

CentOS 7:

- salt-minion 3003.3
- salt-minion 3000.5
- salt-minion 2018.3.3
- salt-minion 2019.2.0

**What it does:**

1. Checks connectivity to the Master.
2. Backs up keys and config.
3. Removes old Salt Minion.
4. Installs Salt Minion 3006.23.
5. Restores keys and restarts the service.
