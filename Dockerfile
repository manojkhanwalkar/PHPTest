# Apache + mod_php on PHP 8.4 (tracks the latest 8.4.x patch release).
FROM docker.io/library/php:8.4-apache AS base

# Production php.ini, Apache listens on unprivileged port 8000 so it can run as
# www-data, and unused modules (directory listings, /server-status) are removed.
RUN set -eux; \
    cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    sed -i 's/^Listen 80$/Listen 8000/' /etc/apache2/ports.conf; \
    sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8000>/' /etc/apache2/sites-available/000-default.conf; \
    a2enmod headers; \
    a2dismod -f autoindex status
COPY docker/php-hardening.ini "$PHP_INI_DIR/conf.d/zz-hardening.ini"
COPY docker/apache-hardening.conf /etc/apache2/conf-available/zz-hardening.conf
RUN a2enconf zz-hardening

# Owned by root, so the www-data server can read but not modify the app.
COPY public/ /var/www/html/
USER www-data
EXPOSE 8000

# Test image: adds the test script; built only by test.sh (--target test).
FROM base AS test
COPY tests/ /app/tests/
CMD ["php", "/app/tests/ServerTest.php"]

# Runtime image (default target): no test code.
FROM base AS runtime
