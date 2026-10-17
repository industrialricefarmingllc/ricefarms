docker service scale ${WORKENV}_$1=0 && docker service scale ${WORKENV}_$1=1 && docker service logs ${WORKENV}_$1 -f --tail 50
