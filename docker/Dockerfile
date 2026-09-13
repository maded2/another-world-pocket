# ============================================================================
# Analogue Pocket openFPGA build environment
# ============================================================================
# Base: Didier Malenfant's ready-made Intel/Altera Quartus Prime image.
#   tag 22.1-apple-silicon == Quartus Prime Lite 22.1std.2 (build 922),
#   Debian 9 (stretch), Cyclone V device support installed, Nios II SDK,
#   license-free (Lite edition).  Built for linux/amd64.
#
# What this layer adds (without touching the ~5.6 GB Quartus install):
#   * Pocket tooling on PATH: build.sh, doctor.sh, new_core.sh,
#     reverse_bits.py, package_core.py
#   * a writable HOME for Quartus logs/licences, owned by whoever runs it
#   * UID/GID-matching entrypoint so build artifacts on the host are yours,
#     not root-owned
#   * /work as the project mount point (+ /build symlink, the convention used
#     by community openFPGA CI images so their scripts keep working)
#
# Deliberately NO `apt-get` here: Debian 9 is off the main mirrors, so
# installing packages is unreliable.  The tooling is stdlib-only Python 3.5+
# and POSIX shell, both already present in the base image.
#
# NOTE on FIX_PERMS: the base image was built with a restrictive umask, so
# ~23k files / ~5k directories of the Quartus install are root-only.  Running
# the tools as your own uid then fails with
#   quartus_sh: error while loading shared libraries: libprotobuf.so.14
# FIX_PERMS=1 repairs the modes (one-off ~4 min, ~1.1 GB extra layer) so that
# builds run unprivileged and artifacts are owned by you.  Set FIX_PERMS=0 for
# a fast, small image and run Quartus as root instead (AP_RUN_AS=root); the
# entrypoint will chown the output back to your uid.
# ============================================================================

ARG BASE_IMAGE=didiermalenfant/quartus:22.1-apple-silicon
FROM ${BASE_IMAGE}

ARG FIX_PERMS=1

LABEL org.opencontainers.image.title="ap-pocket-openfpga-build" \
      org.opencontainers.image.description="Analogue Pocket openFPGA core build env on Quartus Prime Lite" \
      org.opencontainers.image.source="https://github.com/open-fpga/core-template"

# --- repair the base image's root-only Quartus install -----------------------
RUN if [ "$FIX_PERMS" = "1" ]; then \
      echo "repairing /opt/intelFPGA permissions (one-off, ~4 min)..."; \
      chmod -R a+rX /opt/intelFPGA; \
    fi

# --- Quartus dirs that tools want to write into when run as non-root ---------
RUN mkdir -p /opt/intelFPGA/logs /opt/intelFPGA/devdata /opt/intelFPGA/qdesigns \
             /opt/intelFPGA/licenses /tmp/.X11-unix \
 && chmod -R 777 /opt/intelFPGA/logs /opt/intelFPGA/devdata \
               /opt/intelFPGA/qdesigns /opt/intelFPGA/licenses /tmp/.X11-unix \
 && rm -rf /build

# --- tooling -----------------------------------------------------------------
COPY scripts/ /opt/ap-tool/scripts/
COPY docker/entrypoint.sh /usr/local/bin/ap-entrypoint
RUN chmod 755 /opt/ap-tool/scripts/*.sh /opt/ap-tool/scripts/*.py \
              /usr/local/bin/ap-entrypoint \
 && for s in build.sh doctor.sh new_core.sh reverse_bits.py package_core.py; do \
      ln -sf "/opt/ap-tool/scripts/$s" "/usr/local/bin/$s"; \
    done

ENV AP_TOOL=/opt/ap-tool \
    HOME=/work/.home \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    QUARTUS_AUTO_CD_ENABLE=no

WORKDIR /work

# Community openFPGA CI recipes mount the workspace at /build; keep that path
# working so their one-liners run unchanged against this image.
RUN ln -sfn /work /build

ENTRYPOINT ["ap-entrypoint"]
CMD ["bash"]
