# vim: filetype=dockerfile

ARG FLAVOR=${TARGETARCH}

ARG ROCMVERSION=6.1.2
ARG JETPACKVERSION=r35.4.1
ARG CMAKEVERSION=3.31.2

FROM --platform=linux/amd64 ubuntu:22.04 AS base-amd64
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential \
    software-properties-common \
    curl \
    && add-apt-repository ppa:ubuntu-toolchain-r/test \
    && apt-get update && apt-get install -y \
    g++-10 \
    gcc-10 \
    && curl -s -L https://github.com/ccache/ccache/releases/download/v4.10.2/ccache-4.10.2-linux-x86_64.tar.xz | tar -Jx -C /usr/local/bin --strip-components 1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/bin:$PATH

FROM base-amd64 AS base
ARG CMAKEVERSION
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
COPY CMakeLists.txt CMakePresets.json ./
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
ENV LDFLAGS=-s

FROM base AS cpu
RUN apt-get update && apt-get install -y gcc g++ && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/lib/ccache:$PATH
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'CPU' \
        && cmake --build --parallel --preset 'CPU' \
        && cmake --install build --component CPU --strip --parallel 8

FROM base AS cuda-12
ARG CUDA12VERSION=12.4
RUN apt-get update && apt-get install -y curl gnupg wget && \
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub | apt-key add - && \
    echo "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64 /" > /etc/apt/sources.list.d/cuda.list && \
    apt-get update && apt-get install -y cuda-toolkit-${CUDA12VERSION} && \
    rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/cuda-12/bin:$PATH
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'CUDA 12' \
        && cmake --build --parallel --preset 'CUDA 12' \
        && cmake --install build --component CUDA --strip --parallel 8

FROM base AS rocm-6
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'ROCm 6' \
        && cmake --build --parallel --preset 'ROCm 6' \
        && cmake --install build --component HIP --strip --parallel 8

FROM base-amd64 AS jetpack
ARG JETPACKVERSION
RUN apt-get update && apt-get install -y \
    curl ccache \
    && curl -fsSL https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset "JetPack" \
        && cmake --build --parallel --preset "JetPack" \
        && cmake --install build --component CUDA --strip --parallel 8

FROM base AS build
ARG GOVERSION=1.23.4
RUN curl -fsSL https://golang.org/dl/go${GOVERSION}.linux-$(case $(uname -m) in x86_64) echo amd64 ;; esac).tar.gz | tar xz -C /usr/local
ENV PATH=/usr/local/go/bin:$PATH
WORKDIR /go/src/github.com/ollama/ollama
COPY . .
ARG GOFLAGS="'-ldflags=-w -s'"
ENV CGO_ENABLED=1
RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -buildmode=pie -o /bin/ollama .

FROM scratch AS amd64
COPY --from=cuda-12 dist/lib/ollama/cuda_v12 /lib/ollama/cuda_v12

FROM ${FLAVOR} AS archive
COPY --from=cpu dist/lib/ollama /lib/ollama
COPY --from=build /bin/ollama /bin/ollama

FROM ubuntu:22.04
RUN apt-get update \
    && apt-get install -y ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
COPY --from=archive /bin /usr/bin
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
COPY --from=archive /lib/ollama /usr/lib/ollama
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_VISIBLE_DEVICES=all
ENV OLLAMA_HOST=0.0.0.0:11434
EXPOSE 11434
ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
