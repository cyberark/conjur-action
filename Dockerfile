FROM alpine:3.23@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

LABEL org.opencontainers.image.authors="CyberArk Software Ltd."

RUN apk add --no-cache \
	bash=5.3.3-r1 \
	curl=8.19.0-r0 \
	jq=1.8.1-r0 \
	openssl=3.5.6-r0 \
	zlib=1.3.2-r0

COPY --chown=1001:0 entrypoint.sh /conjur-action/entrypoint.sh
COPY --chown=1001:0 CHANGELOG.md /conjur-action/CHANGELOG.md

RUN chmod ug+x /conjur-action/entrypoint.sh \
	&& chmod a-w /conjur-action/entrypoint.sh /conjur-action/CHANGELOG.md

USER 1001

WORKDIR /conjur-action

ENTRYPOINT ["/conjur-action/entrypoint.sh"]
