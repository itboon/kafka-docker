#!/bin/bash

export KAFKA_CONF_FILE="/etc/kafka/server.properties"
export KAFKA_CFG_LOG_DIR="$KAFKA_HOME/data"

if [[ -z "$KAFKA_HOME" ]]; then
  export KAFKA_HOME="/opt/kafka"
  export KAFKA_CFG_LOG_DIR="$KAFKA_HOME/data"
fi
if [[ ! -d "$KAFKA_HOME" ]]; then
  mkdir -p "$KAFKA_HOME"
fi

check_runtime() {
  java -version
  if [[ $? -ne 0 ]]; then
    echo "[ERROR] Missing java"
    exit "500"
  fi
}

run_as_other_user_if_needed() {
  if [[ "$(id -u)" == "0" ]]; then
    # If running as root, drop to specified UID and run command
    exec chroot --userspec=1000:0 / "${@}"
  else
    # Either we are running in Openshift with random uid and are a member of the root group
    # or with a custom --user
    exec "${@}"
  fi
}

get_nodeid_from_suffix() {
  local line="$1"
  local index="${line##*-}"
  if [[ "$index" =~ ^[0-9]+$ ]]; then
    export KAFKA_CFG_NODE_ID="$index"
    if [[ "$KAFKA_NODE_ID_OFFSET" =~ ^[0-9]+$ ]]; then
      if [[ $KAFKA_NODE_ID_OFFSET -gt "0" ]]; then
        export KAFKA_CFG_NODE_ID="$((index + KAFKA_NODE_ID_OFFSET))"
      fi
    fi
  fi
}

fix_external_advertised_listeners() {
  if [[ -z "$KAFKA_EXTERNAL_SERVICE_TYPE" ]]; then
    return
  fi
  if [[ -z "$KAFKA_EXTERNAL_ADVERTISED_LISTENERS" ]]; then
    return
  fi
  local ext_listeners="$KAFKA_EXTERNAL_ADVERTISED_LISTENERS"
  local i="${POD_NAME##*-}"
  local listener=$(echo "$ext_listeners" | cut -d "," -f $((i+1)) | sed 's/ //g')
  if [[ "$KAFKA_EXTERNAL_SERVICE_TYPE" == "NodePort" ]]; then
    listener=$(echo "$listener" | sed -E "s%://[^:]*:%://${POD_HOST_IP}:%")
  fi
  if [[ "$listener" =~ ://[^:]*:[0-9]+$ ]]; then
    export KAFKA_CFG_ADVERTISED_LISTENERS="${KAFKA_CFG_ADVERTISED_LISTENERS},${listener}"
    echo "KAFKA_CFG_ADVERTISED_LISTENERS: $KAFKA_CFG_ADVERTISED_LISTENERS"
  else
    echo "[WARN] KAFKA_EXTERNAL_ADVERTISED_LISTENER invalid, value: [$listener]"
  fi
}

init_nodeid() {
  if [[ "$KAFKA_NODE_ID" =~ ^[0-9]+$ ]]; then
    export KAFKA_CFG_NODE_ID="$KAFKA_NODE_ID"
    return
  fi
  if [[ "$KAFKA_NODE_ID" = hostname* ]]; then
    get_nodeid_from_suffix "$HOSTNAME"
  elif [[ "$KAFKA_NODE_ID" = pod* ]]; then
    if [[ -n "$POD_NAME" ]]; then
      get_nodeid_from_suffix "$POD_NAME"
    fi
  fi
  if [[ -z "$KAFKA_CFG_NODE_ID" ]]; then
    export KAFKA_CFG_NODE_ID="1"
  fi
}

take_file_ownership() {
  if [[ "$(id -u)" == "0" ]]; then
    chown -R 1000:0 "$KAFKA_HOME"
    if [[ -d "$KAFKA_CFG_LOG_DIR" ]]; then
      chown -R 1000:0 "$KAFKA_CFG_LOG_DIR"
    fi
  fi
}

update_server_conf() {
  local key=$1
  local value=$2
  local pattern="$(echo $key | sed 's/\./\\./')"
  sed -i "/^${pattern} *=/d" "$KAFKA_CONF_FILE"
  echo "${key}=${value}" >> "$KAFKA_CONF_FILE"
}

set_kafka_cfg_default() {
  if [[ -z "$KAFKA_CFG_NODE_ID" ]]; then
    export KAFKA_CFG_NODE_ID="1"
  fi
  if [[ -z "$KAFKA_CFG_PROCESS_ROLES" ]]; then
    export KAFKA_CFG_PROCESS_ROLES="broker,controller"
  fi
  if [[ -z "$KAFKA_CFG_INTER_BROKER_LISTENER_NAME" ]]; then
    export KAFKA_CFG_INTER_BROKER_LISTENER_NAME="PLAINTEXT"
  fi
  if [[ -z "$KAFKA_CFG_CONTROLLER_LISTENER_NAMES" ]]; then
    export KAFKA_CFG_CONTROLLER_LISTENER_NAMES="CONTROLLER"
  fi
  if [[ -z "$KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP" ]]; then
    export KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP="CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT"
    export KAFKA_CFG_INTER_BROKER_LISTENER_NAME="INTERNAL"
    export KAFKA_CFG_CONTROLLER_LISTENER_NAMES="CONTROLLER"
  fi
  if [[ -z "$KAFKA_CFG_OFFSETS_TOPIC_REPLICATION_FACTOR" ]]; then
    export KAFKA_CFG_OFFSETS_TOPIC_REPLICATION_FACTOR="1"
  fi
  if [[ -z "$KAFKA_CFG_TRANSACTION_STATE_LOG_REPLICATION_FACTOR" ]]; then
    export KAFKA_CFG_TRANSACTION_STATE_LOG_REPLICATION_FACTOR="1"
  fi
  if [[ -z "$KAFKA_CFG_TRANSACTION_STATE_LOG_MIN_ISR" ]]; then
    export KAFKA_CFG_TRANSACTION_STATE_LOG_MIN_ISR="1"
  fi
  ##
  ## KAFKA_CONTROLLER_LISTENER_PORT default value: 19091
  #local ctl_port="${KAFKA_CONTROLLER_LISTENER_PORT-19091}"
  if [[ -z "$KAFKA_CONTROLLER_LISTENER_PORT" ]]; then
    export KAFKA_CONTROLLER_LISTENER_PORT="19091"
  fi
  ## KAFKA_BROKER_LISTENER_PORT default value: 9092
  #local broker_port="${KAFKA_BROKER_LISTENER_PORT-9092}"
  if [[ -z "$KAFKA_BROKER_LISTENER_PORT" ]]; then
    export KAFKA_BROKER_LISTENER_PORT="9092"
  fi
  if [[ -z "$KAFKA_BROKER_EXTERNAL_PORT" ]]; then
    export KAFKA_BROKER_EXTERNAL_PORT="29092"
  fi
  local ctl_listener="${KAFKA_CFG_CONTROLLER_LISTENER_NAMES}://0.0.0.0:${KAFKA_CONTROLLER_LISTENER_PORT}"
  if [[ -z "$KAFKA_CFG_LISTENERS" ]]; then
    export KAFKA_CFG_LISTENERS="${ctl_listener},${KAFKA_CFG_INTER_BROKER_LISTENER_NAME}://0.0.0.0:${KAFKA_BROKER_LISTENER_PORT}"
    if [[ -n "$KAFKA_BROKER_EXTERNAL_HOST" ]]; then
      local ext_listener="EXTERNAL://0.0.0.0:${KAFKA_BROKER_EXTERNAL_PORT}"
      export KAFKA_CFG_LISTENERS="${KAFKA_CFG_LISTENERS},${ext_listener}"
    fi
  fi
  if [[ -z "$KAFKA_CFG_CONTROLLER_QUORUM_VOTERS" ]]; then
    export KAFKA_CFG_CONTROLLER_QUORUM_VOTERS="${KAFKA_CFG_NODE_ID}@127.0.0.1:${KAFKA_CONTROLLER_LISTENER_PORT}"
  fi
  if [[ -z "$KAFKA_CFG_ADVERTISED_LISTENERS" ]]; then
    get_internal_host
    if echo "$KAFKA_BROKER_INTERNAL_HOST" | grep -E '\S+' &> /dev/null; then
      export KAFKA_CFG_ADVERTISED_LISTENERS="${KAFKA_CFG_INTER_BROKER_LISTENER_NAME}://${KAFKA_BROKER_INTERNAL_HOST}:${KAFKA_BROKER_LISTENER_PORT}"
      if [[ -n "$KAFKA_BROKER_EXTERNAL_HOST" ]]; then
        local ext_listener="EXTERNAL://${KAFKA_BROKER_EXTERNAL_HOST}:${KAFKA_BROKER_EXTERNAL_PORT}"
        export KAFKA_CFG_ADVERTISED_LISTENERS="${KAFKA_CFG_ADVERTISED_LISTENERS},${ext_listener}"
      fi
    fi
  fi
}

get_internal_host() {
  if ip route get 1.1.1.1 &> /dev/null ; then
    local ip="$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')"
    if echo "$ip" | grep -E '([0-9]+\.){3}[0-9]+' &> /dev/null; then
      export KAFKA_BROKER_INTERNAL_HOST="$ip"
    fi
  fi
}

init_server_conf() {
  init_nodeid
  set_kafka_cfg_default
  fix_external_advertised_listeners
  if [[ ! -f "$KAFKA_CONF_FILE" ]]; then
    mkdir -p "$(dirname $KAFKA_CONF_FILE)"
    # cat "${KAFKA_HOME}/config/kraft/server.properties" \
    #   | grep -E '^[a-zA-Z]' > "$KAFKA_CONF_FILE"
    touch "$KAFKA_CONF_FILE"
  fi
  for var in "${!KAFKA_CFG_@}"; do
    # printf '%s=%s\n' "$var" "${!var}"
    key="$(echo "$var" | sed -e 's/^KAFKA_CFG_//' -e 's/_/./g' | tr 'A-Z' 'a-z')"
    value="${!var}"
    update_server_conf "$key" "$value"
  done
}

reset_log_dirs() {
  ## protect log.dirs
  sed -i "/^log.dir *=/d" "$KAFKA_CONF_FILE"
  update_server_conf "log.dirs" "$KAFKA_CFG_LOG_DIR"
}

start_server() {
  check_runtime
  reset_log_dirs
  if [[ -n "$KAFKA_HEAP_OPTS" ]]; then
    export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS} ${KAFKA_HEAP_OPTS}"
  fi
  if [[ ! -f "$KAFKA_CFG_LOG_DIR/meta.properties" ]]; then
    echo ">>> Format Log Directories <<<"
    if [[ -z "$KAFKA_CLUSTER_ID" ]]; then
      echo "Generate a Cluster UUID"
      export KAFKA_CLUSTER_ID="$(${KAFKA_HOME}/bin/kafka-storage.sh random-uuid)"
    fi
    cat "$KAFKA_CONF_FILE"
    if [[ "$(id -u)" == "0" ]]; then
      chroot --userspec=1000:0 / ${KAFKA_HOME}/bin/kafka-storage.sh format \
        -t $KAFKA_CLUSTER_ID -c "$KAFKA_CONF_FILE"
    else
      ${KAFKA_HOME}/bin/kafka-storage.sh format \
        -t $KAFKA_CLUSTER_ID -c "$KAFKA_CONF_FILE"
    fi
  fi
  run_as_other_user_if_needed "${KAFKA_HOME}/bin/kafka-server-start.sh" "$KAFKA_CONF_FILE"
}

init_server_conf
take_file_ownership
if [[ "$@" = "start" ]]; then
  start_server
else
  exec "$@"
fi
