FROM ubuntu:14.04
RUN apt-get -y update
RUN apt-get -y --force-yes install cutter-testing-framework
RUN apt-get -y --force-yes install \
        autoconf \
        automake \
        libtool \
        make \
        gcc \
        g++ \
        libboost-all-dev \
        zlib1g-dev \
        libncursesw5 \
        git \
        libhashkit-dev \
        libtokyocabinet-dev \
        libkyotocabinet-dev \
        uuid-dev \
        libsqlite3-dev \
        libncurses5-dev \
        libcurl4-openssl-dev \
        devscripts \
        git-buildpackage && \
    apt-get clean

ADD . /tmp/flare
RUN cd /tmp/flare && ./autogen.sh && ./configure && make && make install
RUN cd /tmp/flare/test && bash ./run-tests.sh

CMD ["/usr/local/bin/flared", "-f", "/etc/flared.conf"]

