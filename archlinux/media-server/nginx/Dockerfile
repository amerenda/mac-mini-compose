# Use an official Nginx image as the base image
FROM nginx:latest

# Install Certbot and dependencies
RUN apt-get update && apt-get install -y certbot python3-certbot-nginx

# Copy the Nginx configuration template
COPY nginx.conf /etc/nginx/nginx.conf

COPY config/servarr.conf /etc/nginx/conf.d/servarr.conf

# Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /entrypoint.sh

# Expose HTTP and HTTPS ports
EXPOSE 80
EXPOSE 443

# Set the entrypoint script
ENTRYPOINT ["/entrypoint.sh"]

