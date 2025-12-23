# salt-api_scripts
This repository is for install salt-minion automatically, using salt-api, with a script.

To use these scripts, please follow this guide.

Before run this scripts, check the host rm.smeup.com is reachable and on machine, the ports 22, 4505 and 4506 is opened.

## Production

### Register minion
```bash
wget -qO- https://raw.githubusercontent.com/smeup/smeup-provider-utils/master/saltminion.sh | sudo bash -s MINION_ID USERNAME PASSWORD
```

## Testing

### Register minion
```bash
wget -qO- https://raw.githubusercontent.com/smeup/smeup-provider-utils/master/saltminion.sh | sudo bash -s MINION_ID USERNAME PASSWORD
```

## Utility

### Test minion connectivity
```bash
curl -sS https://rm.smeup.com/run -H 'Accept: application/x-yaml' -H 'Content-type: application/json' -d '[{"client":"local","tgt":"MINION_ID","fun":"test.ping","username":"USERNMANE","password":"PASSWORD","eauth": "pam"}]'
```

You can also test all minions using "*" as MINION_ID.
