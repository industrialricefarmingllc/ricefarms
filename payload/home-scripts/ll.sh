docker service logs --tail 10000 ${WORKENV}_$1 | grep $2
