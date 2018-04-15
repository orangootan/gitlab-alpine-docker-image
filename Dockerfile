FROM alpine:3.7

ARG VERSION=10.6.4
ARG DOMAIN=example.com

COPY build.sh entrypoint.sh /docker/
RUN /docker/build.sh

#VOLUME /var/opt/gitlab /var/log /etc/ssh
ENTRYPOINT ["/docker/entrypoint.sh"]
