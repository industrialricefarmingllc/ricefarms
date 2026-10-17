id=$(docker ps -aqf "name=ps2gg_legacy_mongo")
docker exec -it "$id" mongodump --db ps2gg --gzip --archive > /opt/ps2gg/db/backup/mongodb/ps2gg.gz
