FROM alpine:3.6

ARG VERSION=10.0.0
ARG DOMAIN=example.com

COPY build.sh /docker/
RUN /docker/build.sh
COPY entrypoint.sh /docker/

VOLUME /var/opt/gitlab /var/log
ENTRYPOINT ["/docker/entrypoint.sh"]
