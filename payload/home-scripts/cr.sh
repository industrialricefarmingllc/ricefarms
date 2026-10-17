docker-compose restart $@ && docker-compose logs $@ -f --tail 100 # 2>/dev/null
