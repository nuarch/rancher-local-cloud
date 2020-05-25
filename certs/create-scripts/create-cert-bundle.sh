#!/bin/bash

# Taken from here: https://gist.github.com/superseb/175476a5a1ab82df74c7037162c64946 &
# https://dadhacks.org/2017/12/27/building-a-root-ca-and-an-intermediate-ca-using-openssl-and-debian-stretch/
# Based off of instructions here: https://jamielinux.com/docs/openssl-certificate-authority/index.html

PASSWORD=rancher

rootDir=$PWD

mkdir $rootDir/ca
cd $rootDir/ca
mkdir certs crl newcerts private
chmod 700 private
touch index.txt
echo 1000 > serial
cd $rootDir

echo -e "\n### CREATE root key\n"
openssl genrsa -aes256 -passout pass:$PASSWORD -out ca/private/ca.key.pem 4096
chmod 400 ca/private/ca.key.pem

echo -e "\n### CREATE root certificate\n"
openssl req -config root-openssl.cnf -new -x509 \
  -sha512 -extensions v3_ca \
  -passin pass:$PASSWORD \
  -key ca/private/ca.key.pem \
  -out ca/certs/ca.cert.pem \
  -days 820  -set_serial 0

chmod 444 ca/certs/ca.cert.pem

# Intermediate
mkdir $rootDir/ca/intermediate
cd $rootDir/ca/intermediate
mkdir certs crl csr newcerts private
chmod 700 private
touch index.txt
echo 1000 > serial
echo 1000 > $rootDir/ca/intermediate/crlnumber
cd $rootDir

echo -e "\n### Create intermediate key\n"
openssl genrsa -aes256 \
      -passout pass:$PASSWORD \
      -out ca/intermediate/private/intermediate.key.pem 4096
chmod 400 ca/intermediate/private/intermediate.key.pem

echo -e "\n### Create intermediate CSR\n"
openssl req -config intermediate-openssl.cnf \
      -passin pass:$PASSWORD \
      -new -sha512 \
      -key ca/intermediate/private/intermediate.key.pem \
      -out ca/intermediate/csr/intermediate.csr.pem

echo -e "\n### Create/sign intermediate certificate\n"
openssl ca -batch -config root-openssl.cnf \
      -passin pass:$PASSWORD \
      -extensions v3_intermediate_ca \
      -days 820 -notext -md sha512 \
      -in ca/intermediate/csr/intermediate.csr.pem \
      -out ca/intermediate/certs/intermediate.cert.pem
chmod 444 ca/intermediate/certs/intermediate.cert.pem
cat ca/intermediate/certs/intermediate.cert.pem ca/certs/ca.cert.pem > ca/intermediate/certs/ca-chain.cert.pem
chmod 444 ca/intermediate/certs/ca-chain.cert.pem

echo -e "\n### Create certificate key\n"
openssl genrsa -aes256 \
      -passout pass:$PASSWORD \
      -out ca/intermediate/private/local-rancher.key.pem 2048
chmod 400 ca/intermediate/private/local-rancher.key.pem

echo -e "\n### Create certificate CSR\n"
openssl req -config csr-openssl.cnf \
      -passin pass:$PASSWORD \
      -key ca/intermediate/private/local-rancher.key.pem \
      -new -sha512 -out ca/intermediate/csr/local-rancher.csr.pem

echo -e "\n### Create/sign certificate\n"
openssl ca -batch -config intermediate-openssl.cnf \
      -extensions server_cert -days 820 -notext -md sha512 \
      -passin pass:$PASSWORD \
      -in ca/intermediate/csr/local-rancher.csr.pem \
      -out ca/intermediate/certs/local-rancher.cert.pem
chmod 444 ca/intermediate/certs/local-rancher.cert.pem

echo -e "\n### Create files to be used for Rancher\n"
mkdir -p ca/rancher/base64
cp ca/certs/ca.cert.pem ca/rancher/cacerts.pem
cp ca/intermediate/certs/intermediate.cert.pem ca/rancher/intcerts.pem
cat ca/intermediate/certs/local-rancher.cert.pem ca/intermediate/certs/intermediate.cert.pem > ca/rancher/cert.pem


echo -e "\n### Removing passphrase from Rancher certificate key\n"
openssl rsa -passin pass:$PASSWORD -in ca/intermediate/private/local-rancher.key.pem -out ca/rancher/key.pem
if [[ "$OSTYPE" == "darwin"* ]]; then
  cat ca/rancher/cacerts.pem | base64 > ca/rancher/base64/cacerts.base64
  cat ca/rancher/cert.pem | base64 > ca/rancher/base64/cert.base64
  cat ca/rancher/key.pem | base64 > ca/rancher/base64/key.base64
else
  cat ca/rancher/cacerts.pem | base64 -w0 > ca/rancher/base64/cacerts.base64
  cat ca/rancher/cert.pem | base64 -w0 > ca/rancher/base64/cert.base64
  cat ca/rancher/key.pem | base64 -w0 > ca/rancher/base64/key.base64
fi

echo -e "\n### Verify certificates\n"
openssl verify -CAfile ca/certs/ca.cert.pem \
      ca/intermediate/certs/intermediate.cert.pem
openssl verify -CAfile ca/intermediate/certs/ca-chain.cert.pem \
      ca/intermediate/certs/local-rancher.cert.pem

echo -e "\n### Copy certs to temp dir\n"
mkdir -p ../custom/
cp ca/rancher/*.pem ../custom/.

echo -e "\nConvert .pem to .crt\n"
cd ../custom
openssl x509 -outform der -in cert.pem -out cert.crt
openssl x509 -outform der -in cacerts.pem -out intcerts.crt
openssl x509 -outform der -in cacerts.pem -out cacerts.crt
