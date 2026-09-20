# LEGACY / CURRENT-STATE REPRODUCTION -- attacker image (Phase 0 baseline).
# Exactly reproduces the pre-optimisation pattern that produces the PRD bloat:
#   - FROM kalilinux/kali-rolling (unpinned, "latest" semantics)   [FR-02 risk]
#   - Single stage: apt cache + package index lists BAKED in         [FR-01 bloat]
#   - Heavy tools via apt (metasploit-framework, nmap, sqlmap, hydra, wordlists)
#     representative of the kali-tools-top10 metapackage usage        [FR-03 monolith]
#   - sshd installed and auto-started at boot (resident daemon)       [FR-18 violation]
#   - msfconsole auto-started at boot (resident heavy framework)       [FR-18 violation]
#   - runs as root, no USER directive                                 [NFR-03 violation]
#   - NO HEALTHCHECK                                                  [FR-07 absence]
#   - NO resource limits applied at runtime (orchestrator's docker run had none) [FR-06]
# Build:  docker build -f legacy-images/attacker/Dockerfile -t platform/attacker:legacy .

FROM kalilinux/kali-rolling

ENV DEBIAN_FRONTEND=noninteractive

# Heavy toolset representative of kali-tools-top10 usage. metapackage-style single RUN;
# apt lists and cache intentionally NOT cleaned so they bake into final layers (FR-01).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      metasploit-framework \
      nmap \
      sqlmap \
      hydra \
      openssh-server \
      wordlists \
      procps \
 && mkdir -p /run/sshd /root/.ssh \
 && echo 'root:root' | chpasswd \
 && sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

WORKDIR /root
VOLUME ["/root/.msf4"]

COPY legacy-images/attacker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
