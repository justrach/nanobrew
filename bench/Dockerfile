FROM ubuntu:24.04

# Pre-install apt cache so both tools start from same baseline
RUN apt-get update

# Install bc for floating point math in bench script
RUN apt-get install -y bc >/dev/null 2>&1

# Copy nanobrew binary
COPY nb /usr/local/bin/nb
RUN chmod +x /usr/local/bin/nb

# Create nanobrew directories
RUN mkdir -p /opt/nanobrew/cache/blobs /opt/nanobrew/cache/tmp /opt/nanobrew/cache/apt \
    /opt/nanobrew/prefix/bin /opt/nanobrew/prefix/lib /opt/nanobrew/prefix/sbin \
    /opt/nanobrew/db

COPY bench.sh /bench.sh
RUN chmod +x /bench.sh

ENTRYPOINT ["/bench.sh"]
