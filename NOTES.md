# ELB Backend Server Authentication

This is a process for allowing an Elastic Load Balancer to communicate securely with its backing EC2 instances. This is done by generating a private key and self-signed certificate, extracting the public key from the certificate, installing the public key in ELB and the private key and certificate in the EC2 instances.

## Generating the self-signed certificate

```sh
openssl genrsa -out key.pem 2048
openssl req -sha256 -new -key key.pem -out csr.pem
openssl x509 -req -days 365 -in csr.pem -signkey key.pem -out cert.pem
```

## Extract and upload the public key

```sh
openssl x509 -in cert.pem -pubkey -noout

# Copy the contents of the public key, not including the headers on the first and last line

aws elb create-load-balancer-policy --load-balancer-name proxy-elb --policy-name proxy-public-key-policy --policy-type-name PublicKeyPolicyType --policy-attributes AttributeName=PublicKey,AttributeValue="# Paste public key here

aws elb create-load-balancer-policy --load-balancer-name proxy-elb --policy-name proxy-authentication-policy --policy-type-name BackendServerAuthenticationPolicyType --policy-attributes AttributeName=PublicKeyPolicyName,AttributeValue=proxy-public-key-policy

aws elb set-load-balancer-policies-for-backend-server --load-balancer-name proxy-elb --instance-port 443 --policy-names proxy-authentication-policy

# To test

aws elb describe-load-balancer-policies --load-balancer-name proxy-elb
```
