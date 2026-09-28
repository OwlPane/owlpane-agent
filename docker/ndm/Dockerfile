# owlpane-ndm: minimal SNMP + ICMP poller image for the agent chart's ndm component.
# Shell-only on purpose (same rationale as the ops runner): small surface, few CVEs, auditable script.
# openssh-client + sshpass are only exercised by the optional config-backup container.
FROM alpine:3.21
RUN apk add --no-cache net-snmp-tools iputils curl openssh-client sshpass
USER 65532
ENTRYPOINT ["/bin/sh"]
