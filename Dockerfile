ARG GO_VERSION
ARG BASE_IMAGE
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION} AS build
ARG TARGETOS=linux
ARG TARGETARCH
ARG COMMAND=zone-trust-controller
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags='-s -w' -o /out/server ./cmd/${COMMAND}
FROM ${BASE_IMAGE}
COPY --from=build /out/server /server
USER 65532:65532
ENTRYPOINT ["/server"]
