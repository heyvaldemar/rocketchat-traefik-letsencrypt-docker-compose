# Rocket.Chat with Let's Encrypt in a Docker Compose

Install Docker Engine and Docker Compose by following my guide https://www.heyvaldemar.com/install-docker-engine-and-docker-compose-on-ubuntu-server/

Deploy Rocket.Chat server with a Docker Compose using the command:

`docker compose -f rocketchat-traefik-letsencrypt-docker-compose.yml -p rocketchat up -d`
