#!/bin/bash

########################################################################################################################
## Init methods below here
#<editor-fold desc="init methods">

create_certs() {
  if [ ! -d "${WORK_DIR}/certs" ]; then
    sh ./generate-certs.sh "${WORK_DIR}"
  fi
}

create_secrets() {
  declare -A secrets=(
    [test-crt]="${WORK_DIR}/certs/test.crt"
    [test-key]="${WORK_DIR}/certs/test.key"
    [trust-pem]="${WORK_DIR}/certs/myCA.pem"
  )
  for secret_name in "${!secrets[@]}"; do
    podman secret ls --format "{{.Name}}" | grep "${secret_name}" || \
    podman secret create --driver=file "${secret_name}" "${secrets[${secret_name}]}"
  done
}

create_directories() {
  mkdir -p "${WORK_DIR}/nifi/content_repository"
  mkdir -p "${WORK_DIR}/nifi/database_repository"
  mkdir -p "${WORK_DIR}/nifi/flowfile_repository"
  mkdir -p "${WORK_DIR}/nifi/logs"
  mkdir -p "${WORK_DIR}/nifi/persistent-conf/archive"
  mkdir -p "${WORK_DIR}/nifi/provenance_repository"
}

create_data_network() {
  podman network create data_network
}

clean_resources() {
  pushd "${WORK_DIR}" || return
  rm -rf certs/ mongodb/ arangodb/ elasticsearch/ nifi/ traefik/
  popd || exit
}

init_mongodb() {
  if [ ! -d "${WORK_DIR}/mongodb" ]; then
    mkdir -p "${WORK_DIR}/mongodb/db"
    mkdir -p "${WORK_DIR}/mongodb/configdb"
    podman run -d \
     --name mongodb \
     --volume "${WORK_DIR}/mongodb/db":/data/db:Z \
     --volume "${WORK_DIR}/mongodb/configdb":/data/configdb:Z \
     --env "MONGO_INITDB_ROOT_USERNAME=root" \
     --env "MONGO_INITDB_ROOT_PASSWORD=${TEST_PASS}" \
     --env "MONGO_INITDB_DATABASE=admin" \
     --publish "${MONGO_PORT}:${MONGO_PORT}" \
     --userns keep-id \
     docker.io/mongo:"${MONGO_VERSION}" \
      --bind_ip_all \
      --enableFreeMonitoring off
    sleep 10
    echo "MongoDB initialization complete"
    podman container stop mongodb
    podman container rm mongodb
  fi
}

init_elasticsearch() {
  if [ ! -d "${WORK_DIR}/elasticsearch" ]; then
    mkdir -p "${WORK_DIR}/elasticsearch/data"
    podman run -d \
     --name es01 \
     --volume "${WORK_DIR}/elasticsearch/data":/usr/share/elasticsearch/data:Z \
     --env "discovery.type=single-node" \
     --env "ELASTIC_PASSWORD=${TEST_PASS}" \
     --env "xpack.security.enabled=true" \
     --publish "${ELASTIC_PORT}:${ELASTIC_PORT}" \
     --userns keep-id \
     docker.io/elasticsearch:"${ELK_VERSION}"
    echo "Waiting for Elasticsearch availability"
    until curl -s http://localhost:"${ELASTIC_PORT}" | grep -q "missing authentication credentials"; do
      sleep 10
    done
    echo "Setting kibana_system password"
    until curl -s -X POST -u "elastic:${TEST_PASS}" -H "Content-Type: application/json" http://localhost:"${ELASTIC_PORT}"/_security/user/kibana_system/_password -d "{\"password\":\"${TEST_PASS}\"}" | grep -q "^{}"; do
      sleep 10
    done
    echo "Elasticsearch initialization complete"
    podman container stop es01
    podman container rm es01
  fi
}

init_arangodb() {
  if [ ! -d "${WORK_DIR}/arangodb" ]; then
    mkdir -p "${WORK_DIR}/arangodb/apps"
    mkdir -p "${WORK_DIR}/arangodb/data"
  fi
}

copy_traefik_files() {
  cp -r traefik "${WORK_DIR}/"
}

provision_data_resources() {
  create_certs
  create_directories
  init_mongodb
  init_arangodb
  init_elasticsearch
  copy_traefik_files
}

#</editor-fold>
## Init methods above here
########################################################################################################################

source ./.env
provision_data_resources