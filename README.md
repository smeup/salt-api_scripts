# Salt API scripts

This repository is for install salt-minion automatically, using salt-api, with a script.

To use these scripts, please follow this guide.
Before run this scripts, check the host rm.smeup.com is reachable and on machine, the ports 22, 4505 and 4506 is opened.

When you run the script, it will check the MTU of the network interface and will warn you if it is greater than 1500.

**In this version, the script is interactive, so you need to provide the minion id, username and password after launch the script, not at the end of the command!**

## Connect to Production installation

### Register minion

```bash
wget -qO- https://bit.ly/saltapi | sudo bash -s
```

## Connect to Testing installation

First, add on your host file this value:

```bash
3.253.51.223    salt.smeup.com
```

### Register minion

```bash
wget -qO- https://bit.ly/saltapitest | sudo bash -s
```

### Legacy command to register minion

```bash
wget -qO- https://bit.ly/saltapitest | sudo bash -s MINION_ID USERNAME PASSWORD
```

## Development Installation

For development purposes, if you need to install a specific Salt version or use a different Salt Master, you can use salt-api_dev.sh.

```bash
wget -qO- https://bit.ly/saltapidev | sudo bash -s
```

### Features

- **Interactive Master Selection**: Defaults to `rm.smeup.com` but allows override.
- **Smart Version Selection**:
  - Fetches available versions from GitHub.
  - Filters and displays the last **5 versions of the 3007 (STS)** branch.
  - Filters and displays the last **5 versions of the 3006 (LTS)** branch.
  - Allows manual version entry if needed.

## Utility

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

You can also test all minions using "\*" as MINION_ID.
