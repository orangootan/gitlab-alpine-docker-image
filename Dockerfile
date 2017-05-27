FROM alpine:3.6

ARG VERSION=9.2.2
ARG DOMAIN=example.com

COPY build.sh /docker/
RUN /docker/build.sh
COPY entrypoint.sh /docker/

EXPOSE 22 80 443
VOLUME /var/opt/gitlab /var/log
ENTRYPOINT ["/docker/entrypoint.sh"]
