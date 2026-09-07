# Clean-room test for install-zwift-wine.sh.
#
# Builds an environment matching a fresh Ubuntu desktop, then the entrypoint
# runs the real installer and asserts the things that actually break:
#   - .NET 4.8 present (NOT wine-mono)  <- the failure this repo exists for
#   - wine-mono removed
#   - Zwift + RunFromProcess installed
#   - ZwiftLauncher.exe does not exit 200
#
# No GPU and no real display, so this validates the INSTALL path only. It cannot
# verify rendering, sensors or the game itself.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling the installer expects on a desktop system, plus Xvfb to give wine
# a display and winbind for wine's ntlm_auth.
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo ca-certificates curl unzip xvfb winbind procps \
    && rm -rf /var/lib/apt/lists/*

# wine refuses to run as root, so test as an unprivileged user with passwordless
# sudo — which is also how a real user runs the installer.
RUN useradd -m -s /bin/bash zwift \
    && echo 'zwift ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/zwift \
    && chmod 0440 /etc/sudoers.d/zwift

# apt lists are needed by the installer's own apt-get install step
RUN apt-get update

COPY --chown=zwift:zwift install-zwift-wine.sh zwift.sh /home/zwift/repo/
COPY --chown=zwift:zwift test/entrypoint.sh /home/zwift/entrypoint.sh
RUN chmod +x /home/zwift/repo/*.sh /home/zwift/entrypoint.sh

USER zwift
WORKDIR /home/zwift
ENTRYPOINT ["/home/zwift/entrypoint.sh"]
