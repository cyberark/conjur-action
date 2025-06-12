FROM alpine:3.19

RUN apk add --no-cache bash curl jq

RUN mkdir -p /conjur-action

COPY entrypoint.sh /conjur-action/entrypoint.sh

COPY CHANGELOG.md /conjur-action/CHANGELOG.md

RUN chmod +x /conjur-action/entrypoint.sh

WORKDIR /conjur-action

ENTRYPOINT ["/conjur-action/entrypoint.sh"]