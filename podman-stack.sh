#!/bin/bash

########################################################################################################################
## Global script variables below here
#<editor-fold desc="global vars">

MONGO_VERSION=6.0.3
ARANGO_VERSION=3.10.2
ELK_VERSION=8.5.3
GRAFANA_VERSION=9.3.2
TRAEFIK_VERSION=2.9.6

DATA_DASHBOARD_PORT=8444
MONGO_PORT=27017
ARANGO_ROOT_PASSWORD=test123
ARANGO_PORT=8529
ELASTIC_PASSWORD=test123
ELASTIC_PORT=9200
KIBANA_PASSWORD=test123
KIBANA_PORT=5601
GRAFANA_PORT=3000
NIFI_PORT=8088
WORK_DIR=/tmp

#</editor-fold>
## Global script variables above here
########################################################################################################################

########################################################################################################################
## Init methods below here
#<editor-fold desc="init methods">

create_certs() {
  if [ ! -d ${WORK_DIR}/certs ]; then
    sh ./generate-certs.sh ${WORK_DIR}
  fi
}

create_secrets() {
  declare -A secrets=(
    [test-crt]="${WORK_DIR}"/certs/test.crt
    [test-key]="${WORK_DIR}"/certs/test.key
    [trust-pem]="${WORK_DIR}"/certs/myCA.pem
  )
  for secret_name in "${!secrets[@]}"; do
    podman secret ls --format "{{.Name}}" | grep "${secret_name}" || \
    podman secret create --driver=file "${secret_name}" "${secrets[${secret_name}]}"
  done
}

create_data_network() {
  podman network create data_network --internal
}

remove_data_network() {
  podman network rm data_network
}

clean_resources() {
  pushd ${WORK_DIR} || return
  rm -rf certs/ mongodb/ arangodb/ elasticsearch/
  popd || exit
}

provision_data_resources() {
  create_certs
  init_mongodb
  init_arangodb
  init_elasticsearch
}

init_mongodb() {
  if [ ! -d ${WORK_DIR}/mongodb ]; then
    mkdir -p "${WORK_DIR}"/mongodb/configdb
    mkdir -p "${WORK_DIR}"/mongodb/db
    podman run -d \
     --name mongodb \
     --volume ${WORK_DIR}/mongodb/db:/data/db:Z \
     --env "MONGO_INITDB_ROOT_USERNAME=root" \
     --env "MONGO_INITDB_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}" \
     --env "MONGO_INITDB_DATABASE=admin" \
     --publish ${MONGO_PORT}:${MONGO_PORT} \
     --userns keep-id \
     docker.io/mongo:${MONGO_VERSION} \
      --bind_ip_all \
      --enableFreeMonitoring off
    sleep 10
    echo "MongoDB initialization complete"
    podman container stop mongodb
    podman container rm mongodb
  fi
}

init_elasticsearch() {
  if [ ! -d ${WORK_DIR}/elasticsearch ]; then
    mkdir -p "${WORK_DIR}"/elasticsearch/data
    podman run -d \
     --name es01 \
     --volume ${WORK_DIR}/elasticsearch/data:/usr/share/elasticsearch/data:Z \
     --env discovery.type=single-node \
     --env ELASTIC_PASSWORD=${ELASTIC_PASSWORD} \
     --env xpack.security.enabled=true \
     --publish ${ELASTIC_PORT}:${ELASTIC_PORT} \
     --userns keep-id \
     docker.io/elasticsearch:${ELK_VERSION}
    echo "Waiting for Elasticsearch availability"
    until curl -s http://localhost:${ELASTIC_PORT} | grep -q "missing authentication credentials"; do
      sleep 10
    done
    echo "Setting kibana_system password"
    until curl -s -X POST -u "elastic:${ELASTIC_PASSWORD}" -H "Content-Type: application/json" http://localhost:${ELASTIC_PORT}/_security/user/kibana_system/_password -d "{\"password\":\"${KIBANA_PASSWORD}\"}" | grep -q "^{}"; do
      sleep 10
    done
    echo "Elasticsearch initialization complete"
    podman container stop es01
    podman container rm es01
  fi
}

init_arangodb() {
  if [ ! -d ${WORK_DIR}/arangodb ]; then
    mkdir -p ${WORK_DIR}/arangodb/apps
    mkdir -p ${WORK_DIR}/arangodb/data
  fi
}

#</editor-fold>
## Init methods above here
########################################################################################################################

########################################################################################################################
## Stop methods below here
#<editor-fold desc="stop methods">

stop_mongodb() {
  podman container stop data_mongodb
  podman container rm data_mongodb
  podman pod stop mongodb
  podman pod rm mongodb
}

stop_arangodb() {
  podman container stop data_arangodb
  podman container rm data_arangodb
  podman pod stop arangodb
  podman pod rm arangodb
}

stop_elasticsearch() {
  podman container stop es01
  podman container rm es01
  podman pod stop elasticsearch01
  podman pod rm elasticsearch01
}

stop_kibana() {
  podman container stop kibana1
  podman container rm kibana1
  podman pod stop kibana
  podman pod rm kibana
}

stop_grafana() {
  podman container stop grafana1
  podman container rm grafana1
  podman pod stop grafana
  podman pod rm grafana
}

stop_nifi() {
  podman container stop nifi1
  podman container rm nifi1
  podman pod stop nifi
  podman pod rm nifi
}

stop_data_proxy() {
  podman container stop traefik_proxy_data
  podman container rm traefik_proxy_data
  podman pod stop data_proxy
  podman pod rm data_proxy
}

stop() {
  stop_mongodb
  stop_arangodb
  stop_elasticsearch
  stop_kibana
  stop_grafana
  stop_nifi
  stop_data_proxy
  remove_data_network
}

#</editor-fold>
## Stop methods above here
########################################################################################################################

########################################################################################################################
## Start methods below here
#<editor-fold desc="start methods">

start_mongodb() {
  podman pod create \
   --name mongodb \
   --hostname mongodb \
   --infra-name mongodb-infra \
   --userns keep-id \
   --sysctl net.ipv6.conf.all.disable_ipv6=1 \
   --sysctl net.ipv6.conf.default.disable_ipv6=1 \
   --network data_network

  podman run -d \
   --name data_mongodb \
   --pod mongodb \
   --volume ${WORK_DIR}/mongodb/db:/data/db:Z \
   docker.io/mongo:${MONGO_VERSION} \
    --quiet \
    --bind_ip_all \
    --auth \
    --enableFreeMonitoring off \
    --journal
}

start_arangodb() {
  podman pod create \
   --name arangodb \
   --hostname arangodb \
   --infra-name arangodb-infra \
   --userns keep-id \
   --sysctl net.ipv6.conf.all.disable_ipv6=1 \
   --sysctl net.ipv6.conf.default.disable_ipv6=1 \
   --network data_network

  podman run -d \
   --name data_arangodb \
   --pod arangodb \
   --volume ${WORK_DIR}/arangodb/data:/var/lib/arangodb3:Z \
   --volume ${WORK_DIR}/arangodb/apps:/var/lib/arangodb3-apps:Z \
   --env ARANGO_ROOT_PASSWORD=${ARANGO_ROOT_PASSWORD} \
   docker.io/arangodb:${ARANGO_VERSION}
}

start_elasticsearch() {
  podman pod create \
   --name elasticsearch01 \
   --hostname elasticsearch01 \
   --infra-name elasticsearch-infra \
   --userns keep-id \
   --sysctl net.ipv6.conf.all.disable_ipv6=1 \
   --sysctl net.ipv6.conf.default.disable_ipv6=1 \
   --network data_network

  podman run -d \
   --pod elasticsearch01 \
   --name es01 \
   --volume ${WORK_DIR}/elasticsearch/data:/usr/share/elasticsearch/data:Z \
   --env discovery.type=single-node \
   --env ELASTIC_PASSWORD=${ELASTIC_PASSWORD} \
   --env xpack.security.enabled=true \
   docker.io/elasticsearch:${ELK_VERSION}
}

start_kibana() {
  podman pod create \
   --name kibana \
   --hostname kibana \
   --infra-name kibana-infra \
   --sysctl net.ipv6.conf.all.disable_ipv6=1 \
   --sysctl net.ipv6.conf.default.disable_ipv6=1 \
   --network data_network

  podman run -d \
   --name kibana1 \
   --pod kibana \
   --env SERVERNAME=kibana \
   --env ELASTICSEARCH_HOSTS=http://elasticsearch01:${ELASTIC_PORT} \
   --env ELASTICSEARCH_USERNAME=kibana_system \
   --env ELASTICSEARCH_PASSWORD=${KIBANA_PASSWORD} \
   docker.io/kibana:${ELK_VERSION}
}

start_grafana() {
  podman pod create \
   --name grafana \
   --hostname grafana \
   --infra-name grafana-infra \
   --sysctl net.ipv6.conf.all.disable_ipv6=1 \
   --sysctl net.ipv6.conf.default.disable_ipv6=1 \
   --network data_network

  podman run -d \
   --name grafana1 \
   --pod grafana \
   docker.io/grafana/grafana:${GRAFANA_VERSION}
}

start_nifi() {
  podman pod create \
   --name nifi \
   --hostname nifi \
   --userns keep-id \
   --infra-name nifi-infra \
   --sysctl net.ipv6.conf.all.disable_ipv6=1 \
   --sysctl net.ipv6.conf.default.disable_ipv6=1 \
   --network data_network

  podman run -d \
   --name nifi1 \
   --pod nifi \
   --volume ./nifi/content_repository:/opt/nifi/nifi-current/persistent-conf:Z \
   --volume ./nifi/content_repository:/opt/nifi/nifi-current/content_repository:Z \
   --volume ./nifi/database_repository:/opt/nifi/nifi-current/database_repository:Z \
   --volume ./nifi/flowfile_repository:/opt/nifi/nifi-current/flowfile_repository:Z \
   --volume ./nifi/logs:/opt/nifi/nifi-current/logs:Z \
   --volume ./nifi/provenance_repository:/opt/nifi/nifi-current/provenance_repository:Z \
   -e NIFI_WEB_HTTP_PORT=${NIFI_PORT} \
   -e SINGLE_USER_CREDENTIALS_USERNAME=admin \
   -e SINGLE_USER_CREDENTIALS_PASSWORD=test123 \
   docker.io/apache/nifi:latest
}

start_data_proxy() {
  podman pod create \
   --name data_proxy \
   --hostname data_proxy \
   --infra-name data-proxy-infra \
   --network data_network \
   --sysctl net.ipv6.conf.all.disable_ipv6=1 \
   --sysctl net.ipv6.conf.default.disable_ipv6=1 \
   --publish ${DATA_DASHBOARD_PORT}:${DATA_DASHBOARD_PORT} \
   --publish ${MONGO_PORT}:${MONGO_PORT} \
   --publish ${ARANGO_PORT}:${ARANGO_PORT} \
   --publish ${ELASTIC_PORT}:${ELASTIC_PORT} \
   --publish ${KIBANA_PORT}:${KIBANA_PORT} \
   --publish ${GRAFANA_PORT}:${GRAFANA_PORT} \
   --publish ${NIFI_PORT}:${NIFI_PORT}

  podman run -d \
   --name traefik_proxy_data \
   --pod data_proxy \
   --secret source=test-crt,target=/certs/test.crt,type=mount \
   --secret source=test-key,target=/certs/test.key,type=mount \
   --secret source=trust-pem,target=/certs/trust.pem,type=mount \
   --volume ./traefik/data/config:/etc/traefik/dynamic:Z \
   --volume ./traefik/data/credentials.txt:/etc/credentials.txt:Z \
   docker.io/traefik:${TRAEFIK_VERSION} \
    --global.checkNewVersion=false \
    --global.sendAnonymousUsage=false \
    --accessLog=true \
    --accessLog.format=json \
    --api=true \
    --api.dashboard=true \
    --entrypoints.websecure.address=:${DATA_DASHBOARD_PORT} \
    --entrypoints.mongo-tcp.address=:${MONGO_PORT} \
    --entrypoints.arango-http.address=:${ARANGO_PORT} \
    --entrypoints.elasticsearch-http.address=:${ELASTIC_PORT} \
    --entrypoints.kibana-http.address=:${KIBANA_PORT} \
    --entrypoints.grafana-http.address=:${GRAFANA_PORT} \
    --entrypoints.nifi-http.address=:${NIFI_PORT} \
    --providers.file.directory=/etc/traefik/dynamic
}

start() {
  provision_data_resources
  create_secrets
  create_data_network
  start_mongodb
  start_arangodb
  start_elasticsearch
  start_kibana
  start_grafana
  start_nifi
  start_data_proxy
}

#</editor-fold>
## Start methods above here
########################################################################################################################

########################################################################################################################
## Option Processor below here
#<editor-fold desc="option processor">

case "$1" in
  -c|--clean)
    clean_resources
    ;;
  -s|--start)
    start
    ;;
  -t|--stop)
    stop
    ;;
  *) echo "Invalid option selected!"
    exit 1
    ;;
esac

#</editor-fold>
## Option Processor above here
########################################################################################################################
