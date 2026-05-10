#! /bin/sh

NIC=eth0
HTTP_PROXY_DIR=/work/http_proxy
TYPE=""
PX_IP=""
NET_ID=""
USER=""
PASS=""
PORT=""
SOCKID=""

if [ ! -d /work ]; then
  mkdir /work
fi

if [ ! -d "$HTTP_PROXY_DIR" ]; then
  mkdir "$HTTP_PROXY_DIR"
fi

apply_port(){

  while true; do
    port=$(shuf -i 10001-30000 -n 1)

    iptables -t nat -S | grep -q $port
    if [ $? -ne 0 ]; then
        PORT=$port
      break
    fi

  done

}

apply_user_pass(){

  password=$(echo -n "$PORT" | md5sum | head -c 8)
  username=$(echo -n "$PORT$SOCKID" | md5sum | head -c 8)
  USER=$username
  echo "生成 Sock5 代理用户名 $USER"
  PASS=$password
  echo "生成 Sock5 代理密码 $PASS"
}

add() {

  if [ -z "$PX_IP" ] || [ -z "$NET_ID" ]; then
    echo "add 需要同时传入 --pxip 和 --netid"
    exit 1
  fi

  apply_port
  echo "生成 Sock5 代理端口号 $PORT"
  WORK_DIR_NAME=${PX_IP}_${NET_ID}
  WORK_DIR_PATH="$HTTP_PROXY_DIR/$WORK_DIR_NAME"

  if [ -d "$WORK_DIR_PATH" ]; then
    echo "Sock5 容器使用的 $PX_IP 已存在, 添加失败， 请重新输入要创建的容器原IP地址"
    exit 1
  else
    echo "Http Proxy 工作目录为： $WORK_DIR_PATH"
    mkdir "$WORK_DIR_PATH"
  fi

  cd "$WORK_DIR_PATH"

  SOCKID=$NET_ID

  apply_user_pass

  DOCKER_NAME=sk-$PX_IP-$PORT-$NET_ID
  echo "生成 Sock5 容器名称为 $DOCKER_NAME"

  BR_NAME=br-$PORT
  echo "生成 Sock5 容器网络名称为 $BR_NAME"

  NET=172.20.$NET_ID.0/24
  echo "生成 Sock5 容器网络为 $NET"

  IP=172.20.$NET_ID.2
  echo "生成 Sock5 容器IP地址为 $IP"

  echo "添加iptables 规则 "
  iptables -D INPUT -i $NIC -p tcp --dport $PORT -j ACCEPT 2>/dev/null
  iptables -I INPUT -i $NIC -p tcp --dport $PORT -j ACCEPT
  echo "iptables -I INPUT -i $NIC -p tcp --dport $PORT -j ACCEPT"

  iptables -t nat -D Sock5Post -o $NIC -s $NET -j SNAT --to-source $PX_IP  2>/dev/null
  iptables -t nat -I Sock5Post -o $NIC -s $NET -j SNAT --to-source $PX_IP
  echo "iptables -t nat -I POSTROUTING -o $NIC -s $NET -j SNAT --to-source $PX_IP"

  iptables -t nat -D Sock5Pre -i $NIC -d $PX_IP -p tcp --dport $PORT  -j DNAT --to-destination $IP:8080  2>/dev/null
  iptables -t nat -I Sock5Pre -i $NIC -d $PX_IP -p tcp --dport $PORT  -j DNAT --to-destination $IP:8080
  echo "iptables -t nat -I PREROUTING -i $NIC -d $PX_IP -p tcp --dport $PORT  -j DNAT --to-destination $IP:8080"

  echo $USER:$PASS > sockd.passwd

  cat > docker-compose.yml << EOF
services:
  gost-proxy:
    image: gogost/gost
    container_name: $DOCKER_NAME
    restart: always
    command: -L "http://${USER}:${PASS}@:8080"
    networks:
      $BR_NAME:
        ipv4_address: $IP
    ports:
      - $PORT:8080

networks:
  $BR_NAME:
    driver: bridge
    ipam:
      config:
        - subnet: $NET
EOF

#  docker network rm br$PORT
#  docker compose down

  echo "启动容器  docker compose up -d"
  docker compose up -d

  echo "设置账号密码"
#  docker exec sk-$PORT script/pam add $USER $PASS

  cat > config.conf << EOF
EndPoint = $PX_IP:${PORT}
User = $USER
Passwd = $PASS

Port = $PORT
PxIp = $PX_IP
NetId = $NET_ID
Ip = $IP
Network = $NET
DockerName = $DOCKER_NAME
BridgeName= $BR_NAME
EOF

  cat > iptables_del_rule.sh << EOF
#iptables -D INPUT -i $NIC -p tcp --dport $PORT -j ACCEPT
iptables -t nat -D Sock5Post -o $NIC -s $NET -j SNAT --to-source $PX_IP
iptables -t nat -D Sock5Pre -i $NIC -d $PX_IP -p tcp --dport $PORT  -j DNAT --to-destination $IP:8080
EOF
  chmod +x iptables_del_rule.sh

  echo "ip= $PX_IP:${PORT}"
  echo "user= ${USER}"
  echo "passwd= ${PASS}"

  #echo "用户名： 密码"
  #echo ${USER}:${PASS}
  #service netfilter-persistent save
  service iptables save
  echo "HTTP PROXY 代理容器 $DOCKER_NAME 添加完成"
}

del(){

  if [ -z "$PX_IP" ]; then
    echo "del 至少需要传入 --pxip"
    exit 1
  fi

  TARGET_DIR=""
  if [ -d "$HTTP_PROXY_DIR/$PX_IP" ]; then
    TARGET_DIR="$HTTP_PROXY_DIR/$PX_IP"
  else
    for dir in "$HTTP_PROXY_DIR"/${PX_IP}_*; do
      if [ ! -d "$dir" ]; then
        continue
      fi

      if [ -n "$NET_ID" ] && [ -f "$dir/config.conf" ]; then
        grep -q "^NetId = $NET_ID$" "$dir/config.conf" || continue
      fi

      if [ -n "$TARGET_DIR" ]; then
        echo "匹配到多个目录，请提供更精确的 --pxip 或补充 --netid"
        exit 1
      fi

      TARGET_DIR="$dir"
    done
  fi

  if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    echo "Sock5 容器ID $PX_IP 不存在, 删除失败， 请重新输入"
    exit 1
  fi

  cd "$TARGET_DIR"

  if [ "$NET_ID" = "iptables" ]; then
    echo "清除 iptables 规则"
    /bin/sh "$TARGET_DIR/iptables_del_rule.sh"
  else
    echo "清除 iptables 规则"
    /bin/sh "$TARGET_DIR/iptables_del_rule.sh"
    echo "删除 sock5 容器 "
    docker compose down
    cd ..
    echo "$TARGET_DIR"
    rm -rf "$TARGET_DIR"

  fi
#  service netfilter-persistent save
  service iptables save

}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --type)
        TYPE=$2
        shift 2
        ;;
      --pxip)
        PX_IP=$2
        shift 2
        ;;
      --netid)
        NET_ID=$2
        shift 2
        ;;
      --help|-h)
        TYPE=help
        shift
        ;;
      *)
        echo "未知参数: $1"
        exit 1
        ;;
    esac
  done
}

menu() {
  case $TYPE in
    add)
      add
      ;;
    del)
      del
      ;;
    help|"")
      echo ""
      echo "install Dante sockt service docker container scripts"
      echo ""
      echo "Usage:"
      echo "  install.sh --type [add|del] --pxip [proxy_ip] --netid [network_id]"
      echo ""
      echo "Available Commands:"
      echo "  --type add --pxip [proxy_ip] --netid [network_id]"
      echo "  --type del --pxip [proxy_ip] --netid [network_id]"
      echo ""
      echo "Flags:"
      echo "  --type"
      echo "  --pxip"
      echo "  --netid"
      echo "  -h, --help"
      ;;
    *)
      echo "未知 type: $TYPE"
      exit 1
      ;;
  esac
}

parse_args "$@"
menu