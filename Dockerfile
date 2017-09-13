FROM alpine:3.6

ARG VERSION=9.5.4
ARG DOMAIN=example.com

COPY build.sh /docker/
RUN /docker/build.sh
COPY entrypoint.sh /docker/

VOLUME /var/opt/gitlab /var/log
ENTRYPOINT ["/docker/entrypoint.sh"]
