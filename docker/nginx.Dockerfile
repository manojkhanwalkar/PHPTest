# nginx reverse proxy (tracks the latest stable release).
FROM docker.io/library/nginx:stable-alpine
RUN rm -f /etc/nginx/conf.d/default.conf
COPY docker/nginx.conf /etc/nginx/nginx.conf
USER nginx
EXPOSE 8443
