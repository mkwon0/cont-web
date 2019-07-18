#!/bin/bash

SERVICE_NAME=service

#### tpcc_bench variables
TPCC_PATH=/home/mkwon/docker-web/devel/tpcc-mysql
DB_NAME=tpcc_bench

#### Parameters
NUM_DEV=4
TEST_TYPE=web
ARR_SCALE=(1) # total # of containers = SCALE * 4

#### Container parameters
ARR_SWAP_TYPE=(private)

pid_waits () {
    echo "$(tput setaf 4 bold)$(tput setab 7)Waiting the pids$(tput sgr 0)"
    PIDS=("${!1}")
    for pid in "${PIDS[*]}"; do
        wait $pid
    done
}

pid_kills() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Kill the pids$(tput sgr 0)"
	PIDS=("${!1}")
	for pid in "${PIDS[*]}"; do
		kill -15 $pid
	done
}

nvme_format() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Format nvme block devices$(tput sgr 0)"
    for DEV_ID in $(seq 1 ${NUM_DEV}); do
        nvme format /dev/nvme1n${DEV_ID} -n ${DEV_ID} --ses=0
    done
    sleep 1

    FLAG=true
    while $FLAG; do
        NUSE="$(nvme id-ns /dev/nvme1n1 -n 1 | grep nuse | awk '{print $3}')"
        if [[ $NUSE -eq "0" ]]; then
            FLAG=false
            echo "nvme format done"
        fi
    done
    sleep 1
}

nvme_flush() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Flush nvme block devices$(tput sgr 0)"
    for DEV_ID in $(seq 1 ${NUM_DEV}); do
        nvme flush /dev/nvme1n${DEV_ID}
    done
}

docker_remove() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Start removing existing docker$(tput sgr 0)"
	rm -rf $INTERNAL_DIR && mkdir -p $INTERNAL_DIR
    docker ps -aq | xargs --no-run-if-empty docker stop \
    && docker ps -aq | xargs --no-run-if-empty docker rm \
	&& docker system prune --all -f \
    && systemctl stop docker

	for DEV_ID in $(seq 1 4); do
		if [ -e /mnt/nvme1n${DEV_ID}/swapfile ]; then
			/home/mkwon/src/util-linux-swap/swapoff /mnt/nvme1n${DEV_ID}/swapfile
		fi
	done

    for DEV_ID in $(seq 1 4); do
        if mountpoint -q /mnt/nvme1n${DEV_ID}; then
            umount /mnt/nvme1n${DEV_ID}
        fi
        rm -rf /mnt/nvme1n${DEV_ID} \
        && mkdir -p /mnt/nvme1n${DEV_ID} \
        && wipefs --all --force /dev/nvme1n${DEV_ID}
    done

	targets=($(brctl show | grep br- | awk '{print $1}'))
	for target in ${targets[@]}; do
		ifconfig $target down
		brctl delbr $target
	done
}

docker_init() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Initializing docker engine$(tput sgr 0)"
    for DEV_ID in $(seq 1 ${NUM_DEV}); do
        mkfs.xfs /dev/nvme1n${DEV_ID} \
        && mount /dev/nvme1n${DEV_ID} /mnt/nvme1n${DEV_ID}
    done

	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		DEV_ID=$(($((${SCALE_ID}-1))%${NUM_DEV}+1))
		MNT_DIR=/mnt/nvme1n${DEV_ID}
		NGINX_DIR=${MNT_DIR}/nginx-log${SCALE_ID}
		PHP_DIR1=${MNT_DIR}/php-log${SCALE_ID}
		PHP_DIR2=${MNT_DIR}/webpage${SCALE_ID}
		DB_DIR1=${MNT_DIR}/db-data${SCALE_ID}
		DB_DIR2=${MNT_DIR}/db-init${SCALE_ID}

		mkdir -p $NGINX_DIR $PHP_DIR1 $PHP_DIR2 $DB_DIR1 $DB_DIR2

		cp /home/mkwon/docker-web/devel/container-php/webpage/index.php ${PHP_DIR2}/index.php
		cp /home/mkwon/docker-web/devel/container-php/docker/database/mysql-init-files/setup.sql ${DB_DIR2}/setup.sql		
		cp /home/mkwon/docker-web/devel/container-php/docker/php/www.conf ${MNT_DIR}/php${SCALE_ID}.conf
		cp /home/mkwon/docker-web/devel/container-php/docker/nginx/default.conf ${MNT_DIR}/nginx${SCALE_ID}.conf
		cp /home/mkwon/docker-web/devel/container-php/docker/php/Dockerfile ${MNT_DIR}/Dockerfile
		cp /home/mkwon/docker-web/devel/container-php/docker/database/my.cnf ${MNT_DIR}/my.cnf
	done

	iptables -t nat -N DOCKER
	iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
	iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL ! --dst 172.17.0.1/8 -j DOCKER

	service iptables save
	service iptables restart
	iptables -L
	systemctl restart docker

	>/var/log/messages
}

swapfile_init() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Initializing private swapfile$(tput sgr 0)"

	let SWAPSIZE="1024 * $NUM_SCALE"
	for DEV_ID in $(seq 1 4); do
		SWAPFILE=/mnt/nvme1n${DEV_ID}/swapfile
		if [ ! -f $SWAPFILE ]; then
			dd if=/dev/zero of=$SWAPFILE bs=1M count=$SWAPSIZE # 1G
			chmod 600 $SWAPFILE
			mkswap $SWAPFILE
		fi
		if [ $SWAP_TYPE == "private" ]; then
			echo "/mnt/nvme1n${DEV_ID}/swapfile swap swap defaults,cgroup 0 0" >> /etc/fstab
		else
			echo "/mnt/nvme1n${DEV_ID}/swapfile swap swap defaults,pri=60 0 0" >> /etc/fstab
		fi
	done

	/home/mkwon/src/util-linux-swap/swapon -a
	cat /proc/swaps | grep cgroup

	awk '$1 !~/swapfile/ {print }' /etc/fstab > /etc/fstab.bak
	rm -rf /etc/fstab && mv /etc/fstab.bak /etc/fstab
}

docker_healthy() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Check docker healthy$(tput sgr 0)"
	while docker ps -a | grep -c 'starting\|unhealthy' > /dev/null;
	do
		sleep 1;
	done
}


dockerfile_gen() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Generating docker-compose file$(tput sgr 0)"
	ls | grep -P "docker-compose\d+" | xargs -d"\n" rm
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		DEV_ID=$(($((${SCALE_ID}-1))%${NUM_DEV}+1))
		NGINX_PORT=$((8079+${SCALE_ID}))
		DB_PORT=$((3306+${SCALE_ID}))

		case $DEV_ID in
			1)
				MEM_RATIO=20
				;;
			2)
				MEM_RATIO=40
				;;
			3)
				MEM_RATIO=60
				;;
			4)
				MEM_RATIO=100
				;;
			*)
		esac

		let DB_MEM="720 * $MEM_RATIO / 100"
		PHP_MEM=25
		NGINX_MEM=24

		cp docker-compose.yml docker-compose${SCALE_ID}.yml
		sed -i "s|app-network|app-network${SCALE_ID}|" docker-compose${SCALE_ID}.yml
		sed -i "s|db-data|db-data${SCALE_ID}|" docker-compose${SCALE_ID}.yml
		sed -i "s|db-init|db-init${SCALE_ID}|" docker-compose${SCALE_ID}.yml
		sed -i "s|webpage|webpage${SCALE_ID}|" docker-compose${SCALE_ID}.yml
		sed -i "s|php-log|php-log${SCALE_ID}|" docker-compose${SCALE_ID}.yml
		sed -i "s|php.conf|php${SCALE_ID}.conf|" docker-compose${SCALE_ID}.yml
		sed -i "s|nginx.conf|nginx${SCALE_ID}.conf|" docker-compose${SCALE_ID}.yml
		sed -i "s|nginx-log|nginx-log${SCALE_ID}|" docker-compose${SCALE_ID}.yml
		sed -i "s|8080|${NGINX_PORT}|" docker-compose${SCALE_ID}.yml
		sed -i "s|3307|${DB_PORT}|" docker-compose${SCALE_ID}.yml
		sed -i "s|\${MNT_DIR}|/mnt/nvme1n${DEV_ID}|" docker-compose${SCALE_ID}.yml
		sed -i "s|\${DB_MEM}|${DB_MEM}|" docker-compose${SCALE_ID}.yml
		sed -i "s|\${PHP_MEM}|${PHP_MEM}|" docker-compose${SCALE_ID}.yml
		sed -i "s|\${NGINX_MEM}|${NGINX_MEM}|" docker-compose${SCALE_ID}.yml

		if [ $SWAP_TYPE == "public" ]; then
			sed -i '/swapfile/d' docker-compose${SCALE_ID}.yml
		fi
	done
}

docker_web_gen() {
    echo "$(tput setaf 4 bold)$(tput setab 7)Generating web containers$(tput sgr 0)"
	
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		docker-compose -f docker-compose${SCALE_ID}.yml -p ${SERVICE_NAME}${SCALE_ID} build --no-cache --parallel
	done

	GEN_PIDS=()
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		docker-compose -f docker-compose${SCALE_ID}.yml -p ${SERVICE_NAME}${SCALE_ID} up -d & GEN_PIDS+=("$!")
	done
	pid_waits GEN_PIDS[@]

	sleep 5
	docker_healthy
}

docker_web_init() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Initializing web container tables$(tput sgr 0)"
	TPCC_PIDS=()
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		DB_CONT_NAME=database_1
		CONT_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${SERVICE_NAME}${SCALE_ID}_${DB_CONT_NAME})" \
		&& ${TPCC_PATH}/tpcc_load -h $CONT_IP -d $DB_NAME -u test -p testpassword -w 2 & TPCC_PIDS+=("$!")
	done
	pid_waits TPCC_PIDS[@]
	sleep 5
}

log_cleanup() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Enable logging$(tput sgr 0)"
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		DEV_ID=$(($((${SCALE_ID}-1))%${NUM_DEV}+1))
		MNT_DIR=/mnt/nvme1n${DEV_ID}
		>${MNT_DIR}/nginx-log${SCALE_ID}/api_access.log
		>${MNT_DIR}/php-log${SCALE_ID}/access.log
		>${MNT_DIR}/db-data${SCALE_ID}/mysql-slow.log
	done
}

docker_web_run() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Execute TPCC-bench$(tput sgr 0)"
	log_cleanup

	TPCC_PIDS=()
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		PORT_NUM=$((8079+${SCALE_ID}))
		${TPCC_PATH}/tpcc_start -h http://127.0.0.1:${PORT_NUM}/index.php -P ${PORT_NUM} -w 2 -c 50 -r 0 -l 20 & TPCC_PIDS+=("$!")
	done
	pid_waits TPCC_PIDS[@]
	sleep 5
}

log_copy() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Copy logs$(tput sgr 0)"
	for SCALE_ID in $(seq 1 ${NUM_SCALE}); do
		DEV_ID=$(($((${SCALE_ID}-1))%${NUM_DEV}+1))
		MNT_DIR=/mnt/nvme1n${DEV_ID}
		cp ${MNT_DIR}/nginx-log${SCALE_ID}/api_access.log $INTERNAL_DIR/nginx${SCALE_ID}.log
		cp ${MNT_DIR}/php-log${SCALE_ID}/access.log $INTERNAL_DIR/php${SCALE_ID}.log
		cp ${MNT_DIR}/db-data${SCALE_ID}/mysql-slow.log $INTERNAL_DIR/mysql${SCALE_ID}.log
		cp docker-compose${SCALE_ID}.yml $INTERNAL_DIR/
	done
}

anal_start() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Enable analysis$(tput sgr 0)"
	BLKTRACE_PIDS=()
	for DEV_ID in $(seq 1 4); do
		blktrace -d /dev/nvme1n${DEV_ID} -w 600 -D ${INTERNAL_DIR} & BLKTRACE_PIDS+=("$!")
	done
}

anal_end() {
	echo "$(tput setaf 4 bold)$(tput setab 7)Disable analysis$(tput sgr 0)"
	pid_kills BLKTRACE_PIDS[@]
	sleep 10
}

for NUM_SCALE in "${ARR_SCALE[@]}"; do
	for SWAP_TYPE in "${ARR_SWAP_TYPE[@]}"; do
		RESULT_DIR=/mnt/data/cont-${TEST_TYPE}/swap-${SWAP_TYPE} && mkdir -p ${RESULT_DIR}
		INTERNAL_DIR=${RESULT_DIR}/SCALE${NUM_SCALE}-v1
		
		#### Docker initialization
		docker_remove
		nvme_flush
		nvme_format

		docker_init
		swapfile_init
		dockerfile_gen
		docker_web_gen
		# docker_web_init
		# anal_start
		# docker_web_run
		# anal_end
		# log_copy
	done
done
