#!/bin/bash
docker service ps --no-trunc ${WORKENV}_${1}
