initial_space=$(df -m / | tail -1 | awk '{print $4}')

# Step 5: Print the difference in disk space
echo "Disk space difference (in KB): $diff_space"
docker rm $(docker ps -aq)
docker image prune -af
docker system prune -af
docker volume rm $(docker volume ls -q)

final_space=$(df -m / | tail -1 | awk '{print $4}')
diff_space=$((initial_space - final_space))

echo ""
echo "Total space reclaimed: ${diff_space}MB"
