# Test scripts

## Connect to Testing installation

First, add on your host file this value:

```bash
18.201.195.159     rm-test.smeup.com
```

## Register minion

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

# Utility

## Check master response

```bash
curl https://rm.smeup.com/login -H 'Accept: application/x-yaml' -d username=USERNAME -d password=PASSWORD -d eauth=pam
```

## Test SSH key generation

```bash
curl https://rm.smeup.com/run -H "Accept: application/json" -d username=USERNAME -d password=PASSWORD -d eauth='pam' -d client='wheel' -d fun='key.gen' -d id_='test-minion-manuale'
```

## Test connectivity

```bash
curl https://rm.smeup.com/run -H 'Accept: application/x-yaml' -H 'Content-type: application/json' -d '[{"client":"local","tgt":"MINION_ID","fun":"test.ping","username":"USERNAME","password":"PASSWORD","eauth": "pam"}]'
```
