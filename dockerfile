# Debian 13 (Trixie)
FROM debian:trixie-slim

LABEL org.opencontainers.image.authors="Romain" \
      com.rdritcom.debian_version="13" \
      com.rdritcom.apache2_version="2.4.67" \
      com.rdritcom.php_version="8.3.30" \
      com.rdritcom.glpi_version="11.0.7"

RUN apt-get update \
    && apt-get install lsb-release ca-certificates curl -yqq \
    # Add Repo
    && curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && dpkg -i /tmp/debsuryorg-archive-keyring.deb \
    && sh -c 'echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list' \
    && sh -c 'echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/apache2/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/apache2.list' \
    && apt-get update \
    && apt-get install -yqq \
        supervisor \
        git \
        mariadb-client \
        apache2 \
        php8.3-fpm \
        php8.3-curl \
        php8.3-gd \
        php8.3-intl \
        php8.3-mysql \
        php8.3-bz2 \
        php8.3-zip \
        php8.3-apcu \
        php8.3-cli \
        php8.3-imap \
        php8.3-mbstring \
        php8.3-dom \
        php8.3-simplexml \
        php8.3-xmlreader \
        php8.3-xmlwriter \
        php8.3-bcmath \
        php8.3-redis \
        php8.3-ldap \
    && apt-get remove --purge -y manpages manpages-dev man-db patch make unattended-upgrades \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/supervisor

RUN a2enmod rewrite proxy_fcgi setenvif \
    && a2enconf php8.3-fpm \
    && mkdir -p /var/www/glpi

RUN ln -sf /dev/stdout /var/log/apache2/access.log \
    && ln -sf /dev/stderr /var/log/apache2/error.log

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD /bin/bash /usr/local/bin/healthcheck.sh

WORKDIR /var/www/glpi
EXPOSE 80

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]