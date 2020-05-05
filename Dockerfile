ARG NGINX_VERSION=1.16.1
ARG NGINX_RTMP_VERSION=1.2.1
ARG FFMPEG_VERSION=4.2.2
ARG STUNNEL_VERSION=5.56

##############################
# Build the NGINX-build image.
FROM alpine:3.11 as build-nginx
ARG NGINX_VERSION
ARG NGINX_RTMP_VERSION

# Build dependencies.
RUN apk add --update \
  build-base \
  ca-certificates \
  curl \
  gcc \
  libc-dev \
  libgcc \
  linux-headers \
  make \
  musl-dev \
  openssl \
  openssl-dev \
  pcre \
  pcre-dev \
  pkgconf \
  pkgconfig \
  zlib-dev

# Get nginx source.
RUN cd /tmp/ && \
  wget https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
  tar zxf nginx-${NGINX_VERSION}.tar.gz && \
  rm nginx-${NGINX_VERSION}.tar.gz

# Get nginx-rtmp module.
RUN cd /tmp/ && \
  wget https://github.com/arut/nginx-rtmp-module/archive/v${NGINX_RTMP_VERSION}.tar.gz && \
  tar zxf v${NGINX_RTMP_VERSION}.tar.gz && rm v${NGINX_RTMP_VERSION}.tar.gz

# Compile nginx with nginx-rtmp module.
RUN cd /tmp/nginx-${NGINX_VERSION} && \
  ./configure \
  --prefix=/usr/local/nginx \
  --add-module=/tmp/nginx-rtmp-module-${NGINX_RTMP_VERSION} \
  --conf-path=/etc/nginx/nginx.conf \
  --with-threads \
  --with-file-aio \
  --with-http_ssl_module \
  --with-debug \
  --with-cc-opt="-Wimplicit-fallthrough=0" && \
  cd /tmp/nginx-${NGINX_VERSION} && make && make install

###############################
# Build the FFmpeg-build image.
FROM alpine:3.11 as build-ffmpeg
ARG FFMPEG_VERSION
ARG PREFIX=/usr/local
ARG MAKEFLAGS="-j4"

# FFmpeg build dependencies.
RUN apk add --update \
  build-base \
  coreutils \
  freetype-dev \
  lame-dev \
  libogg-dev \
  libass \
  libass-dev \
  libvpx-dev \
  libvorbis-dev \
  libwebp-dev \
  libtheora-dev \
  openssl-dev \
  opus-dev \
  pkgconf \
  pkgconfig \
  rtmpdump-dev \
  wget \
  x264-dev \
  x265-dev \
  yasm

RUN echo http://dl-cdn.alpinelinux.org/alpine/edge/community >> /etc/apk/repositories
RUN apk add --update fdk-aac-dev

# Get FFmpeg source.
RUN cd /tmp/ && \
  wget http://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz && \
  tar zxf ffmpeg-${FFMPEG_VERSION}.tar.gz && rm ffmpeg-${FFMPEG_VERSION}.tar.gz

# Compile ffmpeg.
RUN cd /tmp/ffmpeg-${FFMPEG_VERSION} && \
  ./configure \
  --prefix=${PREFIX} \
  --enable-version3 \
  --enable-gpl \
  --enable-nonfree \
  --enable-small \
  --enable-libmp3lame \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libvpx \
  --enable-libtheora \
  --enable-libvorbis \
  --enable-libopus \
  --enable-libfdk-aac \
  --enable-libass \
  --enable-libwebp \
  --enable-postproc \
  --enable-avresample \
  --enable-libfreetype \
  --enable-openssl \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --extra-libs="-lpthread -lm" && \
  make && make install && make distclean

# Cleanup.
#RUN rm -rf /var/cache/* /tmp/*

###############################
# Build the Stunnel image.
FROM alpine:3.11 as build-stunnel
ARG STUNNEL_VERSION

RUN apk add --no-cache gcc musl-dev openssl-dev make

# Get stunnel source
RUN cd /tmp/ && \
  wget https://www.stunnel.org/downloads/stunnel-${STUNNEL_VERSION}.tar.gz && \
  tar zxf stunnel-${STUNNEL_VERSION}.tar.gz && rm stunnel-${STUNNEL_VERSION}.tar.gz
  
# Compile stunnel.
RUN cd /tmp/stunnel-${STUNNEL_VERSION} && \
  ./configure \
  --prefix=/usr \
  --sysconfdir=/etc \
  --localstatedir=/var && \
  cd /tmp/stunnel-${STUNNEL_VERSION} && make && make install DESTDIR=/stunnel-bin

# Cleanup.
RUN rm -rf /var/cache/* /tmp/*

##########################
# Build the release image.
FROM alpine:3.11
LABEL MAINTAINER Johan Romero <johan@spacenative.com>

# Set default ports.
ENV HTTP_PORT 80
ENV HTTPS_PORT 443
ENV RTMP_PORT 1935

RUN apk add --update \
  ca-certificates \
  gettext \
  openssl \
  pcre \
  lame \
  libogg \
  curl \
  libass \
  libvpx \
  libvorbis \
  libwebp \
  libtheora \
  opus \
  rtmpdump \
  x264-dev \
  x265-dev

COPY --from=build-nginx /usr/local/nginx /mnt/user/appdata/nginx-rtmp-stunnel/nginx
COPY --from=build-nginx /etc/nginx /mnt/user/appdata/nginx-rtmp-stunnel/nginx/conf
COPY --from=build-nginx /opt/data /mnt/user/appdata/nginx-rtmp-stunnel/nginx/data
COPY --from=build-nginx /www /mnt/user/appdata/nginx-rtmp-stunnel/nginx/www
COPY --from=build-nginx /opt/certs /mnt/user/appdata/nginx-rtmp-stunnel/nginx/certs

COPY --from=build-ffmpeg /usr/local /mnt/user/appdata/nginx-rtmp-stunnel/ffmpeg
COPY --from=build-ffmpeg /usr/lib/libfdk-aac.so.2 /usr/lib/libfdk-aac.so.2

COPY --from=build-stunnel /stunnel-bin/etc/stunnel /mnt/user/appdata/nginx-rtmp-stunnel/stunnel/config
COPY --from=build-stunnel /stunnel-bin/usr/bin/stunnel /mnt/user/appdata/nginx-rtmp-stunnel/stunnel/bin
COPY --from=build-stunnel /stunnel-bin/usr/lib/stunnel /mnt/user/appdata/nginx-rtmp-stunnel/stunnel/lib

# Add NGINX path, config and static files.
ENV PATH "${PATH}:/usr/local/nginx/sbin"
ADD nginx.conf /etc/nginx/nginx.conf.template
RUN mkdir -p /opt/data && mkdir /www
ADD static /www/static

EXPOSE 1935
EXPOSE 19350
EXPOSE 80

CMD envsubst "$(env | sed -e 's/=.*//' -e 's/^/\$/g')" < \
  /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && \
  nginx
