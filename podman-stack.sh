#!/bin/bash

########################################################################################################################
## Global script variables below here
#<editor-fold desc="global vars">

# App versions
MONGO_VERSION=6.0.3
ARANGO_VERSION=3.10.2
ELK_VERSION=8.5.3
GRAFANA_VERSION=9.3.2
TRAEFIK_VERSION=2.9.6

# App ports
DATA_DASHBOARD_PORT=8444
MONGO_PORT=27017
ARANGO_PORT=8529
ELASTIC_PORT=9200
KIBANA_PORT=5601
GRAFANA_PORT=3000
NIFI_PORT=8088

# Directories
WORK_DIR=/tmp

# Passwords
TEST_PASS=test123

# Partial address (at least) of the host IP address to listen on
# Similar to a subnet, but without trailing ".0" octets
LISTEN_IP="${1:-192.168}"

#</editor-fold>
## Global script variables above here
########################################################################################################################

########################################################################################################################
## Init methods below here
#<editor-fold desc="init methods">

get_listen_ip() {
  local original_arg="${LISTEN_IP}"
  LISTEN_IP=$(ip -4 -o addr | grep "inet ${original_arg}" | awk '{print $4}' | cut -d "/" -f 1)
  IFS='.' read -r -a ip <<< "${LISTEN_IP}"
  if [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]] \
        && [[ ${LISTEN_IP} =~ ^${ORIGINAL_ARGS} ]]; then
    echo "Listening on IP: ${LISTEN_IP}"
  else
    echo "Could not find an IP address bound to this host that corresponds to '${original_arg}'"
    exit 1
  fi
}

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
  pushd ${WORK_DIR} || return
  rm -rf certs/ mongodb/ arangodb/ elasticsearch/
  popd || exit
}

provision_data_resources() {
  get_listen_ip
  create_certs
  create_directories
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
     --env "MONGO_INITDB_ROOT_PASSWORD=${TEST_PASS}" \
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
     --env ELASTIC_PASSWORD=${TEST_PASS} \
     --env xpack.security.enabled=true \
     --publish ${ELASTIC_PORT}:${ELASTIC_PORT} \
     --userns keep-id \
     docker.io/elasticsearch:${ELK_VERSION}
    echo "Waiting for Elasticsearch availability"
    until curl -s http://localhost:${ELASTIC_PORT} | grep -q "missing authentication credentials"; do
      sleep 10
    done
    echo "Setting kibana_system password"
    until curl -s -X POST -u "elastic:${TEST_PASS}" -H "Content-Type: application/json" http://localhost:${ELASTIC_PORT}/_security/user/kibana_system/_password -d "{\"password\":\"${TEST_PASS}\"}" | grep -q "^{}"; do
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

stop_service() {
  local service=${1}
  local pod=${2}
  podman container stop "${service}"
  podman container rm -f "${service}"
  podman pod stop "${pod}"
  podman pod rm -f "${pod}"
}

remove_data_network() {
  podman network rm data_network
}

stop() {
  stop_service data_mongodb mongodb
  stop_service data_arangodb arangodb
  stop_service es01 elasticsearch01
  stop_service kibana1 kibana
  stop_service grafana1 grafana
  stop_service nifi1 nifi
  stop_service proxy_traefik proxy
  remove_data_network
}

#</editor-fold>
## Stop methods above here
########################################################################################################################

########################################################################################################################
## Start methods below here
#<editor-fold desc="start methods">

start_pod() {
  local pod="${1}"
  shift
  local extra_args=("${@}")
  local pod_create_args=(
   --name "${pod}"
   --hostname "${pod}"
   --infra-name "${pod}-infra"
   --userns "keep-id"
   --sysctl "net.ipv6.conf.all.disable_ipv6=1"
   --sysctl "net.ipv6.conf.default.disable_ipv6=1"
   --network "data_network"
  )
  pod_create_args+=("${extra_args[@]}")
  podman pod create "${pod_create_args[@]}"
}

start_mongodb() {
  start_pod mongodb
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
  start_pod arangodb
  podman run -d \
   --name data_arangodb \
   --pod arangodb \
   --volume ${WORK_DIR}/arangodb/data:/var/lib/arangodb3:Z \
   --volume ${WORK_DIR}/arangodb/apps:/var/lib/arangodb3-apps:Z \
   --env ARANGO_ROOT_PASSWORD=${TEST_PASS} \
   docker.io/arangodb:${ARANGO_VERSION}
}

start_elasticsearch() {
  start_pod elasticsearch01
  podman run -d \
   --pod elasticsearch01 \
   --name es01 \
   --volume ${WORK_DIR}/elasticsearch/data:/usr/share/elasticsearch/data:Z \
   --env discovery.type=single-node \
   --env ELASTIC_PASSWORD=${TEST_PASS} \
   --env xpack.security.enabled=true \
   docker.io/elasticsearch:${ELK_VERSION}
}

start_kibana() {
  start_pod kibana
  podman run -d \
   --name kibana1 \
   --pod kibana \
   --env SERVERNAME=kibana \
   --env ELASTICSEARCH_HOSTS=http://elasticsearch01:${ELASTIC_PORT} \
   --env ELASTICSEARCH_USERNAME=kibana_system \
   --env ELASTICSEARCH_PASSWORD=${TEST_PASS} \
   docker.io/kibana:${ELK_VERSION}
}

start_grafana() {
  start_pod grafana
  podman run -d \
   --name grafana1 \
   --pod grafana \
   docker.io/grafana/grafana:${GRAFANA_VERSION}
}

start_nifi() {
  start_pod nifi
  podman run -d \
   --name nifi1 \
   --pod nifi \
   --volume ${WORK_DIR}/nifi/content_repository:/opt/nifi/nifi-current/persistent-conf:Z \
   --volume ${WORK_DIR}/nifi/content_repository:/opt/nifi/nifi-current/content_repository:Z \
   --volume ${WORK_DIR}/nifi/database_repository:/opt/nifi/nifi-current/database_repository:Z \
   --volume ${WORK_DIR}/nifi/flowfile_repository:/opt/nifi/nifi-current/flowfile_repository:Z \
   --volume ${WORK_DIR}/nifi/logs:/opt/nifi/nifi-current/logs:Z \
   --volume ${WORK_DIR}/nifi/provenance_repository:/opt/nifi/nifi-current/provenance_repository:Z \
   -e NIFI_WEB_HTTP_PORT=${NIFI_PORT} \
   -e SINGLE_USER_CREDENTIALS_USERNAME=admin \
   -e SINGLE_USER_CREDENTIALS_PASSWORD=${TEST_PASS} \
   docker.io/apache/nifi:latest
}

start_data_proxy() {
  publish_args=(
    --publish "${LISTEN_IP}:${DATA_DASHBOARD_PORT}:${DATA_DASHBOARD_PORT}"
    --publish "${LISTEN_IP}:${MONGO_PORT}:${MONGO_PORT}"
    --publish "${LISTEN_IP}:${ARANGO_PORT}:${ARANGO_PORT}"
    --publish "${LISTEN_IP}:${ELASTIC_PORT}:${ELASTIC_PORT}"
    --publish "${LISTEN_IP}:${KIBANA_PORT}:${KIBANA_PORT}"
    --publish "${LISTEN_IP}:${GRAFANA_PORT}:${GRAFANA_PORT}"
    --publish "${LISTEN_IP}:${NIFI_PORT}:${NIFI_PORT}"
  )
  start_pod proxy "${publish_args[@]}"
  podman run -d \
   --name proxy_traefik \
   --pod proxy \
   --secret source=test-crt,target=/certs/test.crt,type=mount \
   --secret source=test-key,target=/certs/test.key,type=mount \
   --secret source=trust-pem,target=/certs/trust.pem,type=mount \
   --volume ./traefik/config:/etc/traefik/dynamic:Z \
   --volume ./traefik/credentials.txt:/etc/credentials.txt:Z \
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
