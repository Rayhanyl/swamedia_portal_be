# syntax=docker/dockerfile:1

# ===== Build stage =====
# Uses the official Ballerina image (same distribution pinned in Ballerina.toml) so the
# compiler and bundled JDK always match what `bal build` produces locally.
FROM ballerina/ballerina:2201.13.4 AS build

# The base image's default `ballerina` user doesn't own /home/ballerina/build (created fresh
# by WORKDIR below), so `bal build` fails trying to write Dependencies.toml/target/. This
# stage is discarded after the build, so running it as root is harmless.
USER root
WORKDIR /home/ballerina/build

# Copy dependency manifests first so `bal build` can reuse the Docker layer cache for
# dependency resolution when only source files change.
COPY Ballerina.toml Dependencies.toml ./
COPY main.bal ./
COPY modules ./modules

RUN bal build

# ===== Runtime stage =====
# `bal build` produces a self-contained executable JAR — running it only needs a JRE
# matching the Java version bundled with the build image (OpenJDK 21 for Ballerina
# 2201.13.4), not the full Ballerina toolchain.
#
# NOTE: deliberately NOT an -alpine variant. Ballerina's http module loads netty-tcnative
# (native BoringSSL) at startup for every http:Client it creates — including the WSO2 IS
# client built eagerly at module-init in repositories.bal — and that native library is only
# published for glibc, not musl. On Alpine this fails with
# `UnsatisfiedLinkError: Failed to load any of the given libraries: [netty_tcnative_linux_x86_64 ...]`
# as soon as the app starts. jammy (Ubuntu, glibc) avoids this entirely.
FROM eclipse-temurin:21-jre-jammy AS runtime

RUN groupadd --system ballerina && useradd --system --gid ballerina ballerina
WORKDIR /home/ballerina/app
COPY --from=build /home/ballerina/build/target/bin/swamedia_portal_be.jar ./swamedia_portal_be.jar
RUN chown -R ballerina:ballerina /home/ballerina/app
USER ballerina

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "swamedia_portal_be.jar"]
