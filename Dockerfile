FROM alpine:3.19
LABEL org.opencontainers.image.authors="CyberArk Software Ltd."

RUN apk add --no-cache bash curl jq \
	&& mkdir -p /conjur-action

COPY entrypoint.sh /conjur-action/entrypoint.sh

COPY CHANGELOG.md /conjur-action/CHANGELOG.md

RUN chown -R 1001:0 /conjur-action \
	&& chmod -R g=u /conjur-action \
	&& chmod ug+x /conjur-action/entrypoint.sh \
	&& chmod a-w /conjur-action/entrypoint.sh /conjur-action/CHANGELOG.md 

USER 1001

WORKDIR /conjur-action

ENTRYPOINT ["/conjur-action/entrypoint.sh"]