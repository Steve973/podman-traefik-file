#!/bin/bash

WORK_DIR=$1
HOST=$(hostname)

if [ ! -d "${WORK_DIR}"/certs ]; then
  # create certs dir
  mkdir "${WORK_DIR}"/certs
  # create the CA extension file
  envsubst <./testCA-ext-template.txt >"${WORK_DIR}"/certs/test.ext
  pushd "${WORK_DIR}"/certs

  # generate the local CA key
  openssl genrsa -out ./myCA.key 2048

  # generate the local CA cert
  openssl req -x509 -new -nodes -key ./myCA.key -sha384 -days 999 -out ./myCA.pem -subj "/C=XX/ST=Confusion/L=Somewhere/O=example/CN=CertificateAuthority"

  # create certificate signing request
  openssl req -newkey rsa:4096 -nodes -sha384 -keyout ./test.key -out ./test.csr -subj "/C=XX/ST=Confusion/L=Somewhere/OU=first/OU=a002/OU=third/OU=b004/O=example/CN=$(hostname)"

  # process the signing request and sign with the fake CA
  openssl x509 -req -in ./test.csr -CA ./myCA.pem -CAkey ./myCA.key -CAcreateserial -out ./test.crt -days 999 -sha384 -extfile ./test.ext

  # create a p12 keystore
  openssl pkcs12 -export -out ./test.p12 -name "$(hostname)" -inkey ./test.key -in ./test.crt -passout pass:test -passin pass:

  # create a jks truststore
  keytool -import -trustcacerts -noprompt -alias "$(hostname)" -ext san=dns:localhost,ip:127.0.0.1 -file ./myCA.pem -keystore ./truststore.jks -storepass changeit

  # return to previous dir
  popd
fi
