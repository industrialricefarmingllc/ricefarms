clear && docker service scale -d ${WORKENV}_$1=0 && docker service scale -d ${WORKENV}_$1=1 && docker service logs ${WORKENV}_$1 -f --tail 0 | sed 's/^[^ ]*  *| //' 
