# CyberArk Conjur Secret Fetcher

GitHub Action for secure secrets delivery to your workflow test environment using CyberArk Conjur.

![](https://img.shields.io/badge/Certification%20Level-Trusted-007BFF?link=https://github.com/cyberark/community/blob/master/Conjur/conventions/certification-levels.md) [![](https://github.com/infamousjoeg/conjur-action/workflows/conjur-action%20Test/badge.svg)](https://github.com/infamousjoeg/conjur-action/actions?workflow=conjur-action+Test)

## Requirements

* [CyberArk Conjur](https://conjur.org)

## Usage instructions

### Example

```yaml
on: [push]

jobs:
  test:
    # ...
    steps:
      # ...
      - name: Import Secrets using CyberArk Conjur Secret Fetcher
        uses: infamousjoeg/conjur-action
        with:
          url: ${{ secrets.CONJUR_URL }}
          account: cyberarkdemo
          host_id: ${{ secrets.CONJUR_USERNAME }}
          api_key: ${{ secrets.CONJUR_API_KEY }}
          secrets: db/sqlusername | sql_username; db/sql_password
      # ...
```

### Arguments

#### Required

* `url` - this is the path to your Conjur instance endpoint.  e.g. `https://conjur.cyberark.com:8443`
* `account` - this is the account configured for the Conjur instance during deployment.
* `host_id` - this is the Host ID granted to your application by Conjur when created via policy. e.g. `host/db/github_action`
* `api_key` - this is the API key associated with your Host ID declared previously.
* `secrets` - a semi-colon delimited list of secrets to fetch.  Refer to [Secrets Syntax](#secrets-syntax) in the README below for more details.

#### Optional

* `certificate` - if using a self-signed certificate, provide the contents for validated SSL.

### Secrets Syntax

`{{ conjurVariable1 | envVarName1; conjurVariable2 }}`

The `secrets` argument is a semi-colon (`;`) delimited list of secrets. The list can optionally contain the name to set for the environment variable.

#### Example

`db/sqlusername | sql_username; db/sql_password`

In the above example, the first secret section is `db/sqlusername | sql_username`.  The `|` separates the Conjur Variable ID from the environment variable that will contain the value of the Conjur Variable's value.

The second secret section is `db/sql_password`.  When no name is given for the environment variable, the Conjur Variable Name will be used.  In this example, the value would be set to `SQL_PASSWORD` as the environment variable name.

## Security

### Protecting Arguments

It is recommended to set the URL, Host ID, and API Key values for the Action to function as secrets by going to Settings > Secrets in your GitHub repository and adding them there.  These can then be called in your workflows' YAML file as a variable: `${{ secrets.SECRETNAME }}`

### Masking

The CyberArk Conjur Secret Fetcher GitHub Action utilizes masking prior to setting secret values to the environment.  This prevents output to the console and to logs.

## Contributing

We welcome contributions of all kinds to this repository. For instructions on how to get started and descriptions
of our development workflows, please see our [contributing guide](https://github.com/cyberark/conjur-api-go/blob/master/CONTRIBUTING.md).

## License

This repository is licensed under Apache License 2.0 - see [`LICENSE`](LICENSE) for more details.
