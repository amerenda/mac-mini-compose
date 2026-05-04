# Use the official Certbot image as the base image
FROM certbot/certbot

# Copy the entrypoint.sh script into the container
COPY entrypoint.sh /entrypoint.sh

# Make the script executable
RUN chmod +x /entrypoint.sh

# Set an environment variable inside the Docker container based on the value
# of JELLYFIN_URL from the .env file
ARG JELLYFIN_URL_FROM_ENV
ENV JELLYFIN_URL=$JELLYFIN_URL_FROM_ENV

# Set /bin/sh as the container's entry point and pass the sleep command
ENTRYPOINT ["/entrypoint.sh"]

