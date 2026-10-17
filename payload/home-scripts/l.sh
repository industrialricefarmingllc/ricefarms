clear

logs=$(docker service logs ${WORKENV}_$1 2>/dev/null)

if [ $? -ne 0 ]; then
  docker-compose logs $1 -f --tail 100 # 2>/dev/null
else
  docker service logs ${WORKENV}_$1 -f --tail 100 | sed 's/^[^ ]* *| //'
fi
