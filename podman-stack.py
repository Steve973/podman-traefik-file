import argparse
import os
import subprocess
import time

import netifaces as ni
import requests
from requests.auth import HTTPBasicAuth

########################################################################################################################
# Global script variables below here
# <editor-fold desc="global vars">

# App versions
MONGO_VERSION = '6.0.3'
ARANGO_VERSION = '3.10.2'
ELK_VERSION = '8.5.3'
GRAFANA_VERSION = '9.3.2'
TRAEFIK_VERSION = '2.9.6'

# App ports
DATA_DASHBOARD_PORT = 8444
MONGO_PORT = 27017
ARANGO_PORT = 8529
ELASTIC_PORT = 9200
KIBANA_PORT = 5601
GRAFANA_PORT = 3000
NIFI_PORT = 8088

# Directories
WORK_DIR = '/tmp/data_stack'

# Passwords
TEST_PASS = 'test123'


# </editor-fold>
# Global script variables above here
########################################################################################################################

########################################################################################################################
# Init methods below here
# <editor-fold desc="init methods">

def get_listen_ip(listen_ip):
    ip_address = '0.0.0.0'
    print(f'Checking interfaces for an IP address starting with {listen_ip}')
    for i in ni.interfaces():
        try:
            ni.ifaddresses(i)
            ip = ni.ifaddresses(i)[ni.AF_INET][0]['addr']
            if ip.startswith(listen_ip):
                ip_address = ip
                break
        except ValueError:
            print(f'Interface {i} is not connected or DHCP is not available.')
    return ip_address


def create_certs():
    if not os.path.exists(f'{WORK_DIR}/certs'):
        subprocess.run(f'sh ./generate-certs.sh {WORK_DIR}'.split())


def create_secrets():
    secrets = {
        'test-crt': f'{WORK_DIR}/certs/test.crt',
        'test-key': f'{WORK_DIR}/certs/test.key',
        'trust-pem': f'{WORK_DIR}/certs/myCA.pem'
    }
    for secret_name, secret_value in secrets.items():
        main_ps = subprocess.run('podman secret ls --format "{{.Name}}"'.split(), capture_output=True)
        result = subprocess.run(f'grep "{secret_name}"'.split(), input=main_ps.stdout, capture_output=True)
        if result.returncode != 0:
            subprocess.run(f'podman secret create --driver=file {secret_name} {secret_value}'.split())


def create_directories():
    os.makedirs(f'{WORK_DIR}/nifi/content_repository', exist_ok=True)
    os.makedirs(f'{WORK_DIR}/nifi/database_repository', exist_ok=True)
    os.makedirs(f'{WORK_DIR}/nifi/flowfile_repository', exist_ok=True)
    os.makedirs(f'{WORK_DIR}/nifi/logs', exist_ok=True)
    os.makedirs(f'{WORK_DIR}/nifi/persistent-conf/archive', exist_ok=True)
    os.makedirs(f'{WORK_DIR}/nifi/provenance_repository', exist_ok=True)


def create_data_network():
    subprocess.run('podman network create data_network'.split())


def provision_data_resources(listen_ip):
    get_listen_ip(listen_ip)
    create_certs()
    create_directories()
    init_mongodb()
    init_arangodb()
    init_elasticsearch()


def clean_resources():
    dirs = [
        'certs',
        'mongodb',
        'arangodb',
        'elasticsearch'
    ]
    for stack_dir in dirs:
        os.rmdir(f'{WORK_DIR}/{stack_dir}')


def init_mongodb():
    if not os.path.exists(f'{WORK_DIR}/mongodb'):
        os.makedirs(f'{WORK_DIR}/mongodb/configdb', exist_ok=True)
        os.makedirs(f'{WORK_DIR}/mongodb/db', exist_ok=True)
        podman_args = [
            '--name',
            'mongodb',
            '--volume',
            f'{WORK_DIR}/mongodb/db:/data/db:Z',
            '--env',
            'MONGO_INITDB_ROOT_USERNAME=root',
            '--env',
            'MONGO_INITDB_ROOT_PASSWORD={TEST_PASS}',
            '--env',
            'MONGO_INITDB_DATABASE=admin',
            '--publish',
            f'{MONGO_PORT}:{MONGO_PORT}',
            '--userns',
            'keep-id'
        ]
        mongod_args = [
            '--bind_ip_all',
            '--enableFreeMonitoring',
            'off'
        ]
        start_service(podman_args, f'docker.io/mongo:{MONGO_VERSION}', mongod_args)
        time.sleep(10)
        print('MongoDB initialization complete')
        subprocess.run('podman container stop mongodb'.split())
        subprocess.run('podman container rm mongodb'.split())


def init_arangodb():
    if not os.path.exists(f'{WORK_DIR}/aramgodb'):
        os.makedirs(f'{WORK_DIR}/arangodb/apps', exist_ok=True)
        os.makedirs(f'{WORK_DIR}/arangodb/data', exist_ok=True)


def init_elasticsearch():
    if not os.path.exists(f'{WORK_DIR}/elasticsearch'):
        os.makedirs(f'{WORK_DIR}/elasticsearch/data', exist_ok=True)
        podman_args = [
            '--name',
            'es01',
            '--volume',
            f'{WORK_DIR}/elasticsearch/data:/usr/share/elasticsearch/data:Z',
            '--env',
            'discovery.type=single-node',
            '--env',
            f'ELASTIC_PASSWORD={TEST_PASS}',
            '--env',
            'xpack.security.enabled=true',
            '--publish',
            f'{ELASTIC_PORT}:{ELASTIC_PORT}',
            '--userns',
            'keep-id'
        ]
        start_service(podman_args, f'docker.io/elasticsearch:{ELK_VERSION}')
        print('Waiting for Elasticsearch availability')
        es_base_url = f'http://localhost:{ELASTIC_PORT}'
        response = 'waiting'
        while 'missing authentication credentials' not in response:
            time.sleep(2)
            try:
                response = requests.get(es_base_url).text
            except:
                print("waiting for elasticsearch startup")
        print('Setting kibana_system password')
        es_kibana_pw_url = f'{es_base_url}/_security/user/kibana_system/_password'
        content_type_headers = {'Content-Type': 'application/json'}
        response = 'waiting'
        while '{}' not in response:
            time.sleep(2)
            try:
                response = requests.post(es_kibana_pw_url, data=f'{{"password":"{TEST_PASS}"}}',
                                         auth=HTTPBasicAuth('elastic', f'{TEST_PASS}'),
                                         headers=content_type_headers).text
            except:
                print('Waiting to set elasticsearch kibana password')
        print('Elasticsearch initialization complete')
        subprocess.run('podman container stop es01'.split())
        subprocess.run('podman container rm es01'.split())


# </editor-fold>
# Init methods above here
########################################################################################################################

########################################################################################################################
# Stop methods below here
# <editor-fold desc="stop methods">

def stop_service(service_name, pod_name):
    subprocess.run(f'podman container stop {service_name}'.split())
    subprocess.run(f'podman container rm -f {service_name}'.split())
    subprocess.run(f'podman pod stop {pod_name}'.split())
    subprocess.run(f'podman pod rm -f {pod_name}'.split())


def remove_data_network():
    subprocess.run('podman network rm data_network'.split())


def stop():
    stop_service('data_mongodb', 'mongodb')
    stop_service('data_arangodb', 'arangodb')
    stop_service('es01', 'elasticsearch01')
    stop_service('kibana1', 'kibana')
    stop_service('grafana1', 'grafana')
    stop_service('nifi1', 'nifi')
    stop_service('proxy_traefik', 'proxy')
    remove_data_network()


# </editor-fold>
# Stop methods above here
########################################################################################################################

########################################################################################################################
# Start methods below here
# <editor-fold desc="start methods">

def start_pod(pod_name, extra_pod_args=None):
    if extra_pod_args is None:
        extra_pod_args = []
    pod_create_args = [
        'podman',
        'pod',
        'create',
        '--name',
        f'{pod_name}',
        '--hostname',
        f'{pod_name}',
        '--infra-name',
        f'{pod_name}-infra',
        '--userns',
        'keep-id',
        '--sysctl',
        'net.ipv6.conf.all.disable_ipv6=1',
        '--sysctl',
        'net.ipv6.conf.default.disable_ipv6=1',
        '--network',
        'data_network'
    ]
    subprocess.run(pod_create_args + extra_pod_args)


def start_service(podman_args, image_tag, service_args=None):
    if service_args is None:
        service_args = []
    base_args = [
        'podman',
        'run',
        '--detach'
    ]
    subprocess.run(base_args + podman_args + [image_tag] + service_args)


def start_mongodb():
    start_pod('mongodb')
    podman_args = [
        '--name',
        'data_mongodb',
        '--pod',
        'mongodb',
        '--volume',
        f'{WORK_DIR}/mongodb/db:/data/db:Z'
    ]
    mongod_args = [
        '--quiet',
        '--bind_ip_all',
        '--auth',
        '--enableFreeMonitoring', 'off',
        '--journal'
    ]
    start_service(podman_args, f'docker.io/mongo:{MONGO_VERSION}', mongod_args)


def start_arangodb():
    start_pod('arangodb')
    podman_args = [
        '--name',
        'data_arangodb',
        '--pod',
        'arangodb',
        '--volume',
        f'{WORK_DIR}/arangodb/data:/var/lib/arangodb3:Z',
        '--volume',
        f'{WORK_DIR}/arangodb/apps:/var/lib/arangodb3-apps:Z',
        '--env',
        f'ARANGO_ROOT_PASSWORD={TEST_PASS}'
    ]
    start_service(podman_args, f'docker.io/arangodb:{ARANGO_VERSION}')


def start_elasticsearch():
    start_pod('elasticsearch01')
    podman_args = [
        '--pod',
        'elasticsearch01',
        '--name',
        'es01',
        '--volume',
        f'{WORK_DIR}/elasticsearch/data:/usr/share/elasticsearch/data:Z',
        '--env',
        'discovery.type=single-node',
        '--env',
        f'ELASTIC_PASSWORD={TEST_PASS}',
        '--env',
        'xpack.security.enabled=true',
    ]
    start_service(podman_args, f'docker.io/elasticsearch:{ELK_VERSION}')


def start_kibana():
    start_pod('kibana')
    podman_args = [
        '--name',
        'kibana1',
        '--pod',
        'kibana',
        '--env',
        'SERVERNAME=kibana',
        '--env',
        f'ELASTICSEARCH_HOSTS=http://elasticsearch01:{ELASTIC_PORT}',
        '--env',
        'ELASTICSEARCH_USERNAME=kibana_system',
        '--env',
        f'ELASTICSEARCH_PASSWORD={TEST_PASS}'
    ]
    start_service(podman_args, f'docker.io/kibana:{ELK_VERSION}')


def start_grafana():
    start_pod('grafana')
    podman_args = [
        '--name',
        'grafana1',
        '--pod',
        'grafana'
    ]
    start_service(podman_args, f'docker.io/grafana/grafana:{GRAFANA_VERSION}')


def start_nifi():
    start_pod('nifi')
    podman_args = [
        '--name',
        'nifi1',
        '--pod',
        'nifi',
        '--volume',
        f'{WORK_DIR}/nifi/content_repository:/opt/nifi/nifi-current/persistent-conf:Z',
        '--volume',
        f'{WORK_DIR}/nifi/content_repository:/opt/nifi/nifi-current/content_repository:Z',
        '--volume',
        f'{WORK_DIR}/nifi/database_repository:/opt/nifi/nifi-current/database_repository:Z',
        '--volume',
        f'{WORK_DIR}/nifi/flowfile_repository:/opt/nifi/nifi-current/flowfile_repository:Z',
        '--volume',
        f'{WORK_DIR}/nifi/logs:/opt/nifi/nifi-current/logs:Z',
        '--volume',
        f'{WORK_DIR}/nifi/provenance_repository:/opt/nifi/nifi-current/provenance_repository:Z',
        '--env',
        f'NIFI_WEB_HTTP_PORT={NIFI_PORT}',
        '--env',
        'SINGLE_USER_CREDENTIALS_USERNAME=admin',
        '--env',
        f'SINGLE_USER_CREDENTIALS_PASSWORD={TEST_PASS}',
    ]
    start_service(podman_args, 'docker.io/apache/nifi:latest')


def start_data_proxy(listen_ip):
    publish_args = [
        '--publish',
        f'{listen_ip}:{DATA_DASHBOARD_PORT}:{DATA_DASHBOARD_PORT}',
        '--publish',
        f'{listen_ip}:{MONGO_PORT}:{MONGO_PORT}',
        '--publish',
        f'{listen_ip}:{ARANGO_PORT}:{ARANGO_PORT}',
        '--publish',
        f'{listen_ip}:{ELASTIC_PORT}:{ELASTIC_PORT}',
        '--publish',
        f'{listen_ip}:{KIBANA_PORT}:{KIBANA_PORT}',
        '--publish',
        f'{listen_ip}:{GRAFANA_PORT}:{GRAFANA_PORT}',
        '--publish',
        f'{listen_ip}:{NIFI_PORT}:{NIFI_PORT}'
    ]
    start_pod('proxy', publish_args)
    podman_args = [
        '--name',
        'proxy_traefik',
        '--pod',
        'proxy',
        '--secret',
        'source=test-crt,target=/certs/test.crt,type=mount',
        '--secret',
        'source=test-key,target=/certs/test.key,type=mount',
        '--secret',
        'source=trust-pem,target=/certs/trust.pem,type=mount',
        '--volume',
        './traefik/config:/etc/traefik/dynamic:Z',
        '--volume',
        './traefik/credentials.txt:/etc/credentials.txt:Z'
    ]
    traefik_args = [
        '--global.checkNewVersion=false',
        '--global.sendAnonymousUsage=false',
        '--accessLog=true',
        '--accessLog.format=json',
        '--api=true',
        '--api.dashboard=true',
        f'--entrypoints.websecure.address=:{DATA_DASHBOARD_PORT}',
        f'--entrypoints.mongo-tcp.address=:{MONGO_PORT}',
        f'--entrypoints.arango-http.address=:{ARANGO_PORT}',
        f'--entrypoints.elasticsearch-http.address=:{ELASTIC_PORT}',
        f'--entrypoints.kibana-http.address=:{KIBANA_PORT}',
        f'--entrypoints.grafana-http.address=:{GRAFANA_PORT}',
        f'--entrypoints.nifi-http.address=:{NIFI_PORT}',
        '--providers.file.directory=/etc/traefik/dynamic'
    ]
    start_service(podman_args, f'docker.io/traefik:{TRAEFIK_VERSION}', traefik_args)


def start(listen_ip):
    provision_data_resources(listen_ip)
    create_secrets()
    create_data_network()
    start_mongodb()
    start_arangodb()
    start_elasticsearch()
    start_kibana()
    start_grafana()
    start_nifi()
    start_data_proxy(listen_ip)


# </editor-fold>
# Start methods above here
########################################################################################################################


parser = argparse.ArgumentParser(description='Launch reverse proxied data services.')
parser.add_argument('action',
                    nargs='?',
                    default='start',
                    choices=['start', 'stop', 'clean'],
                    help='the action to perform on the data application stack')
parser.add_argument('--listen-ip',
                    dest='listen_ip',
                    default='192.168',
                    required=False,
                    help='First octets of host IP address to listen on')

args = parser.parse_args()
stackAction = args.action
if stackAction == 'start':
    start(args.listen_ip)
elif stackAction == 'stop':
    stop()
elif stackAction == 'clean':
    clean_resources()
