# External Network

## Using Docker Compose

[examples/docker-compose-bridge.yml](https://github.com/sir5kong/kafka-docker/blob/main/examples/docker-compose-bridge.yml)

``` yaml
version: "3"

volumes:
  kafka-data: {}

### KAFKA_HOST_IP_ADDR -- host ip address
##  Write variables to .env file，for exmaple: KAFKA_HOST_IP_ADDR="172.16.2.32"
###

### Service port and address
##  Controller: 9091
##  Broker Internal: 9092
##  Broker External: 29092
##  bootstrap-server: ${KAFKA_HOST_IP_ADDR}:29092
##  Access web UI http://${KAFKA_HOST_IP_ADDR}:18080
###

services:
  kafka:
    image: sir5kong/kafka:v3.5
    # restart: always
    ports:
      - "29092:29092"
    volumes:
      - kafka-data:/opt/kafka/data
    environment:
      - KAFKA_HEAP_OPTS=-Xmx1024m -Xms1024m
      - KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT
      - KAFKA_CFG_LISTENERS=CONTROLLER://:9091,PLAINTEXT://:9092,EXTERNAL://:29092
      - KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://:9092,EXTERNAL://${KAFKA_HOST_IP_ADDR}:29092
      - KAFKA_CFG_NODE_ID=1
      - KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=1@kafka:9091

  ## Web UI for managing Kafka clusters (optional)
  kafka-ui:
    image: provectuslabs/kafka-ui:v0.7.1
    # restart: always
    ports:
      - "18080:8080"
    environment:
      - KAFKA_CLUSTERS_0_NAME=sir5kong-demo
      - KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS=kafka:9092
      #- KAFKA_CLUSTERS_0_READONLY=true

```

## Using Helm

``` yaml
## LoadBalancer example
broker:
  replicaCount: 3
  external:
    enabled: true
    service:
      type: "LoadBalancer"
      annotations: {}
    domainSuffix: "kafka.example.com"
```

More About [Helm](/helm/#external-access)