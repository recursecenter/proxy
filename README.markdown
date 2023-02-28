# Proxy

Proxy is a nginx-based reverse proxy with TLS that runs on AWS. It was written to be the backend for a Recurse Center custom subdomain service, which lets RC alumni register a recurse.com subdomain for their webapp or website.

Proxy is a front-end for an unlimited number of webapps all hosted at \*.example.com. For each request, Proxy serves a wildcard TLS certificate for that domain.

## Features

- Nightly unattended security updates with zero downtime
- Easy deploys with near-zero downtime
- Dynamic updating of host list from an external HTTPS endpoint
- Secure secret storage with easy secret updating
- Logs to a syslog server (e.g. Papertrail)

## Example config.production.yml

```yml
aws:
  elb_name: proxy-elb
  region: us-east-1
  ami: ami-0a313d6098716f372 # Ubuntu 18.04.2 for us-east-1
  instance_type: m3.medium
  instance_count: 2
  key_name: Dave # you must upload your public key and give it a name on the EC2 dashboard
  security_group: proxy # Used for instances. Should have ports 22 and 443 open.
env:
  PROXY_ENV: production
  PROXY_DOMAIN: recurse.com
  PROXY_DOMAINS_ENDPOINT: https://www.example.com/domain.json

  # Optional

  # Remote logging over TLS. All three variables must be set.
  # PROXY_SYSLOG_DRAIN: logs.papertrailapp.com:12345
  # PROXY_SYSLOG_ROOT_CERTS: https://papertrailapp.com/tools/papertrail-bundle.pem
  # PROXY_SYSLOG_PERMITTED_PEER: "*.papertrailapp.com"
```

## How Proxy works

The infrastructure that Proxy runs on consists of a Classic Load Balancer and a configurable number of EC2 instances (we use 2).

Proxy itself is a few pieces of software:

* A command line tool (bin/proxy) that knows how to boot and configure new EC2 instances, register them with the load balancer, and terminate old ones.
* Nginx listening on port port 443. Requests with X-Forwarded-Proto set to http are redirected to HTTPS, and HTTPS requests are reverse-proxied to the configured hosts.
* A backend (backend/bin/proxy-backend) that is responsible for loading subdomain -> redirect URL mappings from $PROXY_DOMAINS_ENDPOINT, and reloading nginx. By default, this happens every 15 seconds.
* Provisioning scripts (backend/bin/setup, backend/bin/proxy-install) that are responsible for configuring new EC2 instances.

The ELB sits in front of the two instances, which are deployed in separate availability zones for redundency. The ELB loads /healthcheck on each instance to make sure that the instances are running.

The ELB has two listeners: HTTP and HTTPS. Both listeners forward to HTTPS on the instances, using Backend Authentication, which consists of a self-signed certificate and associated private key, generated during the deploy process. The public key gets installed on the ELB during deploy, and the ELB only passes traffic to instances that present a certificate with the same public key.

The instances use Upstart to make sure the proxy-backend daemon is always running. Proxy-backend logs to syslog. You can set the optional PROXY_SYSLOG_DRAIN config option to the URL for a remote syslog server, which can collect the logs from all running instances.

## Loading subdomain mappings

In order to use Proxy, you need a publicly accessible HTTP endpoint that returns a set of mappings from subdomain to URL. The endpoint must return JSON data in the following format:

```
[
  ["subdomain1", "https://www.example.com/foo"],
  ["subdomain2", "https://www.example.net"],
  ["subdomain3", "http://www.example.org"]
]
```

## The deploy process

The code for Proxy's deploy process is located in lib/proxy/deploy.rb. This is a summary of the process:

* Generate self-signed certificate (newly generated each deploy) and dhparams (only generated if necessary)
* Clean up any instances from a failed half-finished deploy
* Add public key from self-signed certificate to the ELB's list of trusted public keys
* Boots new instances
* Uploads a tar file file consisting of everything in `git ls-files`, as well as the production config and certificate files to each instance, extracts the tar on the server, and runs `backend/bin/setup` and `backend/bin/proxy-install production`
* Registers the new instances with the ELB and waits until they are in service.
* Terminates the old instances
* Removes the old trusted public key from the ELB

### What gets deployed

While `bin/proxy` uses `git ls-files` to decide what files get uploaded to the instances, it uses the contents of your working directory, not the contents of the git repository. This means that any local modifications you have will get deployed. This is useful for testing changes to Proxy, but may bite you if you're not careful.

### Broken deploys

Each time you run `bin/proxy deploy`, a random UUID is generated and written to .deploy. This file is removed once the deploy is complete. Each instance that gets deployed is tagged with this UUID.

If `bin/proxy` sees a .deploy file when it is run, it assumes there was a broken deploy and cleans up by terminating all instances tagged with that UUID.

Instances are also tagged with the name "proxy-web" so you can easily see which instances are a part of Proxy.

## How to deploy Proxy

If this is your first time deploying Proxy, you'll have to create a Classic Load Balancer manually. It should be configured to forward both HTTP and HTTPS connections to HTTPS on its instances.

Make sure your AWS credentials are in ~/.aws/credentials. You can configure this with the aws cli: `aws configure`

Next, create config.production.yml file in Proxy's root directory (see above for an example).

Then run `bin/proxy deploy`

## Listing instances

To list instances, run `bin/proxy list`. This is useful for SSHing into the instances for debugging purposes (see below).

This command lists all instances tagged with proxy-web that are either pending, running, or shutting down. There's no guarantee that these instances are registered with the load balancer.

## Debugging proxy

If you were the person who deployed Proxy, you can SSH into the instances and poke around to see what's wrong. Here are places to look:

- `systemctl status proxy`
- `systemctl status nginx`
- /var/log/syslog (proxy logs to syslog)
- /var/log/nginx/{access,error}.log

If you didn't deploy proxy, you won't be able to SSH in. The best you can do is deploy proxy yourself so that the instances have your SSH keys and then wait for the problem to happen again so you can debug via SSH.

If you're debugging the RC proxy instance, you can access the syslog output by going to [Papertrail](https://www.papertrail.com) and logging in using the "Papertrail (Proxy)" credentials in the RC 1Password vault.

## Rebooting proxy

While you can't reboot proxy, the problem might go away if you deploy it again. Make sure your SSH key is set up correctly in the EC2 section of the [AWS Console](console.aws.amazon.com), and referenced in your config.production.yml.

After that, run `bin/proxy deploy`.

## TODO

- TLS session resumption
- WebSocket support (see http://nginx.com/blog/websocket-nginx/)
- Config stored in the cloud to support multiple people deploying
  - In event of broken conf, upload to S3 and include link in error msg

## Copyright

Copyright Recurse Center 2019

## License

AGPLv3 or later
