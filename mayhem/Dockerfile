# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm + libFuzzer/afl++ +
# cmake/ninja/pkg-config + the identities + the build-contract ENV; this layer adds SDL_ttf's own
# native deps (SDL3 + FreeType headers/libs) and the per-commit build.

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an empty
# value breaks clang both here and for any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: undefaulted ARG lets the base ENV flow through to build.sh when not passed,
# and an explicit --build-arg overrides it.
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the ORACLE build to measure suite coverage.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset.
ARG MAYHEM_JOBS=

# SDL_ttf needs SDL3 (headers + the runtime .so the fuzz/KAT binaries dynamically link against)
# and FreeType (the oracle build links the SYSTEM libfreetype; the fuzz build compiles the
# vendored external/freetype submodule from source instead — see mayhem/build.sh). Re-pin to
# SOURCE_DATE_EPOCH first for reproducibility (repro-sources-list.sh ships in the base).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libsdl3-dev \
        libfreetype-dev \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout, with `submodules: recursive` so
# external/freetype is populated): the FULL repo (incl. .git history and the freetype submodule
# working tree) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run SDL_ttf's functional KAT oracle at build time — a failing suite fails the image build, so
# the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
