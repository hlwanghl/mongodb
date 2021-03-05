readonly RS_HOSTS_FILE=/data/appctl/data/rs.hosts

initNode() {
  _initNode
  mkdir -p /data/mongodb/{conf,data,logs}
  chown -R mongod.mongod /data/mongodb
  chown -R syslog.svc /data/mongodb/logs
  [ -f $MONGO_KEY_FILE ] || setUpKeyFile $MONGO_KEY_FILE
  [ -e /data/index.html ] || ln -s /opt/app/current/conf/caddy/index.html /data/
  touch $RS_HOSTS_FILE
}

initCluster() {
  if isFirstNode; then
    setUpRs
    retry 15 2 0 checkRsReady
    retry 5 1 0 setUpFirstUser
    setUpCustomUsers
  fi
  _initCluster
}

startSvc() {
  local svcName=${1%%/*}
  if [ "$svcName" = "mongod" ]; then
    local prevPrimary="$(readRuntimeRsHosts | awk -F/ '$3=="PRIMARY" {print $2}')"
    if [ -n "$prevPrimary" ] && [ "$MY_IP" != "${prevPrimary%:*}" ]; then
      retry 10 1 0 checkEndpoint tcp:$prevPrimary
    fi
    _startSvc $@
    saveRuntimeRsHosts
  else
    _startSvc $@
  fi
}

stopSvc() {
  local svcName=${1%%/*}
  if [ "$svcName" = "mongod" ]; then
    local runtimeRsHosts; runtimeRsHosts="$(getRuntimeRsHosts)"
    local primaryHost=$(echo "$runtimeRsHosts" | awk -F/ '$3=="PRIMARY" {print $2}')
    log "stopping rs '$runtimeRsHosts' ..."
    if [ "$MY_IP" = "${primaryHost%:*}" ]; then
      retry 10 1 0 runMongoCmd --rs 'rs.status().members.filter(m=>m.stateStr!="PRIMARY").length==0||quit(1)'
    fi
    _stopSvc $@
    saveRuntimeRsHosts "$runtimeRsHosts"
  else
    _stopSvc $@
  fi
}

reloadChanges() {
  isClusterInitialized || return 0
  if $IS_UPGRADING; then return 0; fi
  local cmd; for cmd in $RELOAD_COMMANDS; do
    execute ${cmd//:/ }
  done
}

restore() {
  log "restoring ..."
  # TODO: start mongod-local -> rs.reconfig -> stop mongod-local -> start mongod-replset
}

measure() {
  runMongoCmd --file /opt/app/current/bin/node/measure.js
}

getRsMembers() {
  local mongoCmd='JSON.stringify(rs.status().members.map(m => [m.name, m.stateStr]))'
  local members; members="$(runMongoCmd --rs "$mongoCmd" | tail -1)"
  echo '{"labels": ["IP", "Role"], "data": '"$members"'}'
}

getMongoUri() {
  local hosts="$(printf "%s\n" "${STABLE_NODES[@]}" | awk -F/ '{print $3":'$MONGO_PORT'"}' | paste -sd,)"
  local uri="mongodb://$MONGO_USER_CUSTOM:$MONGO_USER_PASSWD@$hosts/admin?replicaSet=$MONGO_RS_NAME"
  echo $uri | jq -Rc '{"labels": ["Mongo URI"], "data": [[.]]}'
}

isFirstNode() {
  [ "$MY_SID" -eq 1 ]
}

readRuntimeRsHosts() {
  cat $RS_HOSTS_FILE || echo
}

saveRuntimeRsHosts() {
  rotate $RS_HOSTS_FILE
  echo "$1" > $RS_HOSTS_FILE
}

getRuntimeRsHosts() {
  local mongoCmd='rs.status().members.map(m=>[m._id,m.name,m.stateStr].join("/")).join(" ")||quit(1)'
  runMongoCmd --rs "$mongoCmd" | tail -1 | xargs -n1 || return 1
}

setUpKeyFile() {
  echo $GLOBAL_UUID | base64 > $1
  chown mongod.mongod $1
  chmod 400 $1
}

setUpRs() {
  local awkCmd='{print $1 - 1, $3":"'$MONGO_PORT', $1 == 1 ? 2 : 1}'
  local jqCmd='[inputs | split(" ") | {_id: .[0] | tonumber, host: .[1], priority: .[2] | tonumber}]'
  local members="$(printf "%s\n" "${STABLE_NODES[@]}" | awk -F/ "$awkCmd" | jq -Rnc "$jqCmd")"
  runMongoCmd --init "rs.initiate({_id: '$MONGO_RS_NAME', members: $members})"
}

checkRsReady() {
  local awkCmd='{printf "%d/%s\n", $1 - 1, $1 == 1 ? "PRIMARY" : "SECONDARY"}'
  local expected="$(printf "%s\n" "${STABLE_NODES[@]}" | awk -F/ "$awkCmd" | sort)"

  local mongoCmd="rs.status().members.map(m => [m._id, m.stateStr].join('/')).join(' ')"
  local actual; actual="$(runMongoCmd --init "$mongoCmd" | tail -1 | xargs -n1 | sort)"

  [ "$expected" = "$actual" ]
}

reloadRsHosts() {
  log "reloading rs hosts ..."
  # TODO: stop mongod-replset -> start mongod-local -> rs.reconfig -> stop mongod-local -> start mongod-replset
}

setUpFirstUser() {
  addMongoUser --init $MONGO_SU_NAME $MONGO_SU_PASS root
}

setUpCustomUsers() {
  addMongoUser --rs $MONGO_USER_ROOT $MONGO_USER_PASSWD root
  addMongoUser --rs $MONGO_USER_CUSTOM $MONGO_USER_PASSWD readWriteAnyDatabase
}

addMongoUser() {
  # Successfully added user: { "user" : "root", "roles" : [ "root" ] }
  runMongoCmd $1 "db.createUser({user: '$2', pwd: '$3', roles: ['$4']})" | grep -o ^Successfully
}

runMongoCmd() {
  local credentials="qc_master:$MONGO_SU_PASS@"
  if [ "$1" = "--init" ]; then credentials=""; shift; fi

  local uri=mongodb://${credentials}127.0.0.1:$MONGO_PORT/admin
  if [ "$1" = "--rs" ]; then uri="$uri?replicaSet=$MONGO_RS_NAME"; shift; fi

  local strArgs="--eval"
  if [ "$1" = "--file" ]; then strArgs=""; shift; fi
  timeout --preserve-status 3 /opt/mongodb/current/bin/mongo --quiet $uri $strArgs "${@:$#}"
}
