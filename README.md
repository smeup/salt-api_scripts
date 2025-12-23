# Salt API scripts

This repository is for install salt-minion automatically, using salt-api, with a script.

To use these scripts, please follow this guide.

Before run this scripts, check the host rm.smeup.com is reachable and on machine, the ports 22, 4505 and 4506 is opened.

## Connect to Production installation

### Register minion

```bash
wget -qO- https://bit.ly/saltapiprod | sudo bash -s MINION_ID USERNAME PASSWORD
```

## Connect to Testing installation

First, add on your host file this value:

```bash
3.253.51.223    salt.smeup.com
```

### Register minion

```bash
wget -qO- https://bit.ly/saltapitest | sudo bash -s MINION_ID USERNAME PASSWORD
```

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
curl https://rm.smeup.com/run -H 'Accept: application/x-yaml' -H 'Content-type: application/json' -d '[{"client":"local","tgt":"MINION_ID","fun":"test.ping","username":"USERNMANE","password":"PASSWORD","eauth": "pam"}]'
```

If you want to try connection with testing installation, change "rm.smeup.com/run" with "salt.smeup.com/run"

You can also test all minions using "*" as MINION_ID.
