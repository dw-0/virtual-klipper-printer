FROM python:3.12-slim-bookworm AS builder

RUN apt-get update && apt-get install -y \
    --no-install-recommends \
    --no-install-suggests \
    ### non-specific packages
    git \
    swig \
    virtualenv \
    ### klipper
    avr-libc \
    binutils-avr \
    build-essential \
    cmake \
    gcc-avr \
    libcurl4-openssl-dev \
    libssl-dev \
    libffi-dev \
    python3-dev \
    python3-libgpiod \
    python3-distutils \
    ### \
    && pip install setuptools \
    ### clean up
    && apt-get -y autoremove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 

WORKDIR /build

### Prepare our applications
#### Klipper
ARG KLIPPER_REPO=https://github.com/Klipper3d/klipper.git
ENV KLIPPER_REPO=${KLIPPER_REPO}
RUN git clone ${KLIPPER_REPO} klipper \
    && virtualenv -p python3 /build/klippy-env \
    && /build/klippy-env/bin/pip install -r /build/klipper/scripts/klippy-requirements.txt

#### Simulavr
COPY config/simulavr.config /usr/src
RUN git clone -b master https://git.savannah.nongnu.org/git/simulavr.git \
    # Build the firmware
    && cd klipper \
    && cp /usr/src/simulavr.config .config \
    && make \
    && cp out/klipper.elf /build/simulavr.elf \
    && rm -f .config \
    && make clean \
    # Build simulavr
    && cd ../simulavr \
    && make python \
    && make build \
    && make clean

#### Moonraker
RUN git clone https://github.com/Arksine/moonraker \
    && virtualenv -p python3 /build/moonraker-env \
    && /build/moonraker-env/bin/pip install -r /build/moonraker/scripts/moonraker-requirements.txt

#### Moonraker Timelapse
RUN git clone https://github.com/mainsail-crew/moonraker-timelapse

#### MJPG-Streamer
RUN git clone --depth 1 https://github.com/jacksonliam/mjpg-streamer \
    && cd mjpg-streamer \
    && cd mjpg-streamer-experimental \
    && mkdir _build \
    && cd _build \
    && cmake -DPLUGIN_INPUT_HTTP=OFF -DPLUGIN_INPUT_UVC=OFF -DPLUGIN_OUTPUT_FILE=OFF -DPLUGIN_OUTPUT_RTSP=OFF -DPLUGIN_OUTPUT_UDP=OFF .. \
    && cd .. \
    && make \
    && rm -rf _build

## --------- This is the runner image

FROM python:3.12-slim-bookworm AS runner
RUN apt-get update && apt-get install -y \
    --no-install-recommends \
    --no-install-suggests \
    ### non-specific packages
    git \
    build-essential \
    supervisor \
    sudo \
    ### moonraker
    curl \
    iproute2 \
    libcurl4-openssl-dev \
    liblmdb-dev \
    libopenjp2-7 \
    libsodium-dev \
    libssl-dev \
    zlib1g-dev \
    libjpeg-dev \
    packagekit \
    wireless-tools \
    ### clean up
    && apt-get -y autoremove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 

RUN groupadd --force -g 1000 printer \
    && useradd -rm -d /home/printer -g 1000 -u 1000 printer \
    && usermod -aG dialout,tty,sudo printer \
    && echo 'printer ALL=(ALL:ALL) NOPASSWD:ALL' >> /etc/sudoers.d/printer

### copy all required files
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY scripts/start.sh /bin/start
COPY scripts/service_control.sh /bin/service_control
COPY scripts/fix_venvs.sh /tmp/fix_venvs.sh

### make entrypoint executable
RUN chmod +x /bin/start
RUN chmod +x /bin/service_control
RUN chmod +x /tmp/fix_venvs.sh

USER printer
WORKDIR /home/printer

# Copy our prebuilt applications from the builder stage
COPY --from=builder --chown=printer:printer /build/klippy-env ./klippy-env
COPY --from=builder --chown=printer:printer /build/klipper/ ./klipper/
COPY --from=builder --chown=printer:printer /build/moonraker ./moonraker
COPY --from=builder --chown=printer:printer /build/moonraker-env ./moonraker-env
COPY --from=builder --chown=printer:printer /build/moonraker-timelapse ./moonraker-timelapse
COPY --from=builder --chown=printer:printer /build/simulavr ./simulavr
COPY --from=builder --chown=printer:printer /build/simulavr.elf ./simulavr.elf
COPY --from=builder --chown=printer:printer /build/mjpg-streamer/mjpg-streamer-experimental ./mjpg-streamer

# Copy example configs and dummy streamer images
COPY ./example-configs/ ./example-configs/
COPY ./mjpg_streamer_images/ ./mjpg_streamer_images/

# Fix shebangs in venv directories
RUN /tmp/fix_venvs.sh

# Remove oneshot script
USER root
RUN rm /tmp/fix_venvs.sh

USER printer
ENTRYPOINT ["/bin/start"]
