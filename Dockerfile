FROM nginx:alpine

# Zkopírujeme vlastní index.html do nginx webroot
COPY index.html /usr/share/nginx/html/index.html

# Exponujeme port 80
EXPOSE 80

# Healthcheck pro ECS
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=2 \
  CMD wget -qO- http://localhost/ || exit 1
